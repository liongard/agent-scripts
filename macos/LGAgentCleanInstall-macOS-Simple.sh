#!/bin/bash
#
# SYNOPSIS
#   Repairs or installs the Liongard Agent on macOS, re-attaching to the same platform record.
#
# DESCRIPTION
#   Set your values in the configuration block below. Exit codes, logs and troubleshooting are in
#   the README under LINK.
#   - Healthy: upgrades only when the package is newer, else exits 0. Never removes it.
#   - Stale (broken, stopped, half removed, or refused by the platform with HTTP 401):
#     saves the agent identity, removes the agent locally, then reinstalls it.
#   - Not installed: saves any identity left behind, then installs.
#   - Waits up to 2 minutes for a running agent update, and tries one start of a stopped agent.
#   - Checks the package before it removes anything. Keeps /etc/liongard-agent.
#
# NOTES
#   Requires:     root, macOS on Intel or Apple Silicon, curl.
#                 Liongard agent install token (key and secret).
#   Author:       Liongard Partner Support
#   Last updated: 2026-10-23
#
# LINK
#   https://github.com/liongard/agent-scripts/blob/main/macos/README.md

# ------------------------------------------------------------
# A. REQUIRED CONFIGURATION
# ------------------------------------------------------------

# Liongard instance: us1, us1.app.liongard.com or https://us1.app.liongard.com.
INSTANCE_URL="REPLACE_WITH_INSTANCE_URL"

# Agent install token (key and secret) that registers the agent.
ACCESS_KEY_ID="REPLACE_WITH_ACCESS_KEY_ID"
ACCESS_KEY_SECRET="REPLACE_WITH_ACCESS_KEY_SECRET"

# Environment to register the agent in. Required when INCLUDE_ENVIRONMENT_VALUE=true.
ENVIRONMENT="REPLACE_WITH_ENVIRONMENT_NAME"

# ------------------------------------------------------------
# B. OPTIONAL CONFIGURATION (every installer value)
# ------------------------------------------------------------

# false registers the agent without an environment; ENVIRONMENT is then not required.
INCLUDE_ENVIRONMENT_VALUE=true

# Agent name. Blank uses the hostname.
NAME=""

# Free-text description. Needs agent package 5.5.0 or later.
AGENT_DESCRIPTION=""

# auto picks the Apple Silicon or Intel package; x64 or arm64 forces one. The Intel package on
# Apple Silicon needs Rosetta 2, which the script installs when it is missing.
MAC_ARCHITECTURE="auto"

# Full path to a .pkg already on this Mac (for example staged by your MDM). Blank downloads it.
PKG_PATH=""

# Root-only folder for the script log and the identity backup.
LOG_DIRECTORY="/Library/Logs/LiongardDeploy"

# Do not edit below this line.

# BEGIN SHARED BLOCK: Liongard shell common functions
# Identical in every Linux and macOS script except LGAgentIdentity-*. Bash 3.2 or later.

EXIT_OK=0
EXIT_UNEXPECTED=1
EXIT_CONFIG=2
EXIT_PREREQUISITE=3
EXIT_ENVIRONMENT=4
EXIT_DOWNLOAD=5
EXIT_INSTALLER=6
EXIT_VALIDATION=7
EXIT_STALE=8
EXIT_REMOVAL=9
EXIT_PLATFORM=10
EXIT_BUSY=11
EXIT_IDENTITY=12

LG_LOG_FILE=""
LG_SECRETS=()
LG_API_BASE=""
LG_API_AUTH=""
LG_ID_AGENT_ID=""
LG_ID_AGENT=""
LG_ID_OS=""

# Masks registered secrets and proxy credentials (user:****@host).
lg_mask() {
    local text="$1" secret
    for secret in ${LG_SECRETS[@]+"${LG_SECRETS[@]}"}; do
        if [ "${#secret}" -ge 4 ]; then text="${text//"${secret}"/****}"; fi
    done
    case "${text}" in
        *@*) printf '%s' "${text}" | sed -E 's#([^:/@[:space:],;="]+):[^/[:space:],;"]*@#\1:****@#g' ;;
        *) printf '%s' "${text}" ;;
    esac
}

lg_add_secret() {
    if [ -n "$1" ]; then LG_SECRETS+=("$1"); fi
}

_log() {
    local line
    line="[$(date '+%Y-%m-%d %H:%M:%S')][$1] $(lg_mask "$2")"
    printf '%s\n' "${line}" >&2
    if [ -n "${LG_LOG_FILE}" ]; then printf '%s\n' "${line}" >> "${LG_LOG_FILE}" 2>/dev/null; fi
    return 0
}
log_info()  { _log INFO "$*"; }
log_step()  { _log STEP "$*"; }
log_ok()    { _log OK "$*"; }
log_warn()  { _log WARN "$*"; }
log_error() { _log ERROR "$*"; }

# Usage: lg_exit <code> <message>
lg_exit() {
    if [ "$1" -eq 0 ]; then log_ok "$2"; else log_error "$2 (exit $1)"; fi
    if [ -n "${LG_LOG_FILE}" ]; then printf 'Log file: %s\n' "${LG_LOG_FILE}" >&2; fi
    exit "$1"
}

lg_require_root() {
    if [ "$(id -u)" -ne 0 ]; then lg_exit "${EXIT_PREREQUISITE}" "Run this script as root (for example with sudo)."; fi
}

# Usage: lg_start_log <folder> <prefix>. The folder is root-only (0700); the 5 newest logs per prefix are kept.
lg_start_log() {
    local dir="${1%/}" old count=0
    if [ -L "${dir}" ] || { [ -e "${dir}" ] && [ ! -d "${dir}" ]; }; then
        lg_exit "${EXIT_PREREQUISITE}" "Log folder ${dir} is a symlink or a file. Refusing to use it."
    fi
    if ! ( umask 077 && mkdir -p "${dir}" ) || [ ! -O "${dir}" ] || ! chmod 700 "${dir}"; then
        lg_exit "${EXIT_PREREQUISITE}" "Log folder ${dir} could not be created as a root-only folder."
    fi
    LG_LOG_FILE="${dir}/$2_$(date '+%Y%m%d_%H%M%S').log"
    if ! ( umask 077 && : > "${LG_LOG_FILE}" ); then
        LG_LOG_FILE=""
        lg_exit "${EXIT_PREREQUISITE}" "Could not create a log file in ${dir}."
    fi
    for old in $(ls -1t "${dir}/$2_"*.log 2>/dev/null); do
        count=$((count + 1))
        if [ "${count}" -gt 5 ]; then rm -f -- "${old}"; fi
    done
    log_info "Logging to ${LG_LOG_FILE}."
}

# True when a value is blank or still a REPLACE_WITH_ placeholder.
lg_is_unset() {
    case "$1" in
        REPLACE_WITH_*) return 0 ;;
    esac
    [ -z "$(printf '%s' "$1" | tr -d '[:space:]')" ]
}

# Usage: lg_require <setting name> <value>
lg_require() {
    if lg_is_unset "$2"; then lg_exit "${EXIT_CONFIG}" "Configuration value [$1] must be set."; fi
}

# Usage: lg_require_bool <setting name> <value>
lg_require_bool() {
    if [ "$2" != true ] && [ "$2" != false ]; then lg_exit "${EXIT_CONFIG}" "$1 must be true or false (got '$2')."; fi
}

# Prints <prefix>.app.liongard.com for us1, us1.app.liongard.com or https://us1.app.liongard.com/.
lg_instance_host() {
    local value
    value="$(printf '%s' "$1" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
    case "${value}" in
        *\?*|*\**|*\[*|*\]*) return 1 ;;
    esac
    value="${value#https://}"
    value="${value#http://}"
    value="${value%%/*}"
    value="${value%.app.liongard.com}"
    if [[ ! "${value}" =~ ^[a-z0-9-]+$ ]]; then return 1; fi
    printf '%s.app.liongard.com' "${value}"
}

lg_version_valid() {
    [[ "$1" =~ ^[0-9]+(\.[0-9]+)*$ ]]
}

# True if version $1 is newer than version $2. Missing parts count as 0.
lg_version_newer() {
    local a b x y i=0
    IFS=. read -r -a a <<< "$1"
    IFS=. read -r -a b <<< "$2"
    while [ "${i}" -lt "${#a[@]}" ] || [ "${i}" -lt "${#b[@]}" ]; do
        x=$((10#${a[i]:-0}))
        y=$((10#${b[i]:-0}))
        if [ "${x}" -gt "${y}" ]; then return 0; fi
        if [ "${x}" -lt "${y}" ]; then return 1; fi
        i=$((i + 1))
    done
    return 1
}

url_encode() {
    local string="$1" encoded="" char i
    for (( i = 0; i < ${#string}; i++ )); do
        char="${string:i:1}"
        case "${char}" in
            [a-zA-Z0-9.~_-]) encoded+="${char}" ;;
            *) encoded+="$(printf '%%%02X' "'${char}")" ;;
        esac
    done
    printf '%s' "${encoded}"
}

# Usage: lg_api_setup <instance host> <api key> <api secret>
lg_api_setup() {
    LG_API_BASE="https://$1/api/v1"
    LG_API_AUTH="$(printf '%s' "$2:$3" | base64 | tr -d '\n')"
    lg_add_secret "${LG_API_AUTH}"
}

# The token reaches curl on stdin, never on the command line.
_lg_curl_auth() {
    printf 'header = "X-ROAR-API-KEY: %s"\n' "${LG_API_AUTH}"
}

# Prints the response body; fails on a network error or a non-2xx status.
_api_get() {
    _lg_curl_auth | curl -sS --fail --max-time 120 --config - \
        -H "User-Agent: LiongardAgentScript/1.0" "${LG_API_BASE}$1"
}

# Prints the HTTP status code (000 when no response arrived).
_api_delete() {
    _lg_curl_auth | curl -sS -o /dev/null -w '%{http_code}' --max-time 120 --config - \
        -X DELETE -H "User-Agent: LiongardAgentScript/1.0" "${LG_API_BASE}$1"
}

# Trims whitespace (including a trailing newline), strips enclosing braces and lowercases.
lg_id_key() {
    printf '%s' "$1" | tr -d '[:space:]' | sed -E 's/^\{(.*)\}$/\1/' | tr '[:upper:]' '[:lower:]'
}

# True for values that must never be a match key: empty, local, uninitialized, all-zero, or no hex digit.
lg_is_junk_id() {
    local key
    key="$(lg_id_key "$1")"
    case "${key}" in
        ""|local|uninitialized) return 0 ;;
    esac
    if [ -z "$(printf '%s' "${key}" | tr -d '0{}-')" ]; then return 0; fi
    case "${key}" in
        *[0-9a-f]*) return 1 ;;
    esac
    return 0
}

# Usage: lg_id_add <list variable> <source> <value>. Appends "source=value" unless junk or already listed.
lg_id_add() {
    local list value key
    eval "list=\"\${$1}\""
    value="$(printf '%s' "$3" | tr -d '[:space:]')"
    if lg_is_junk_id "${value}"; then return 0; fi
    key="$(lg_id_key "${value}")"
    if printf '%s\n' "${LG_ID_AGENT}${LG_ID_OS}" | cut -d= -f2- | while IFS= read -r v; do lg_id_key "${v}"; echo; done | grep -Fxq -- "${key}"; then
        return 0
    fi
    printf -v "$1" '%s%s=%s\n' "${list}" "$2" "${value}"
}

lg_values() {
    printf '%s' "$1" | cut -d= -f2- | sed '/^$/d'
}

# True when the last 3 heartbeat results in an agent log are HTTP 401 (the platform refuses the agent).
# Network errors have no status code and never match.
lg_heartbeat_rejected() {
    local lines
    [ -r "$1" ] || return 1
    lines="$(tail -n 500 "$1" 2>/dev/null | grep '"caller":"http/heartbeat\.go' | tail -n 3)"
    [ "$(printf '%s\n' "${lines}" | grep -c '"status_code":401[^0-9]')" -eq 3 ]
}

# END SHARED BLOCK: Liongard shell common functions

# BEGIN SHARED BLOCK: Liongard macOS agent functions
# Identical in every macos/LGAgent*.sh script except LGAgentIdentity-macOS.sh.

LG_AGENT_DIR=/Library/Liongard
LG_AGENT_CONFIG=/Library/Liongard/.config.json
LG_AGENT_BINARY=/Library/Liongard/LiongardAgent
LG_AGENT_LOG=/Library/Liongard/logs/agent.log
LG_PKG_UNINSTALL=/Library/Liongard/uninstall.sh
LG_GUID_DIR=/etc/liongard-agent
LG_GUID_FILE=/etc/liongard-agent/.machine-guid
LG_DAEMON_DIR=/Library/LaunchDaemons
LG_LABEL=com.liongard.liongard-agent
LG_UPDATER_LABEL=com.liongard.liongard-agent-updater
LG_LABELS="${LG_LABEL} ${LG_UPDATER_LABEL}"
LG_RECEIPTS="com.liongard.LiongardAgent com.liongard.liongard-agent.app"
LG_PKG_URL_X64="https://agents.static.liongard.com/LiongardAgent-lts.pkg"
LG_PKG_URL_ARM64="https://agents.static.liongard.com/LiongardAgent-lts-arm64.pkg"
LG_PKG_MIN_BYTES=20000000
LG_PKG_TEAM_ID="KU4C98N3LW"
LG_HANDOFF_FILES="/tmp/liongard_instance_url /tmp/liongard_access_key_id /tmp/liongard_access_key_secret /tmp/liongard_name /tmp/liongard_environment /tmp/liongard_description"
LG_VALUES_FILE=/tmp/temporary-liongard-values.txt
LG_PKG_LOG=/tmp/liongard-agent-installer.log
LG_MACHINE_GUID_PATTERN='^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'
LG_STATE=""
LG_WORK_DIR=""
LG_TMP=""
LG_PKG=""
LG_PKG_VERSION=""
LG_HOST_ARCH=""
LG_INSTALL_HOST=""
LG_INSTALL_ENVIRONMENT=""
LG_ID_VALUE=""
LG_ID_SOURCE=""
LG_ID_LEGACY=false

# Reads a string value from the agent config with the same sed the package uses.
lg_config_value() {
    [ -r "${LG_AGENT_CONFIG}" ] || return 0
    sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "${LG_AGENT_CONFIG}" 2>/dev/null | head -1
}

# Usage: lg_launchd_running <label>. True when launchd reports the job as running.
lg_launchd_running() {
    launchctl print "system/$1" 2>/dev/null | grep -q 'state = running'
}

lg_service_running() {
    [ -f "${LG_DAEMON_DIR}/${LG_LABEL}.plist" ] && lg_launchd_running "${LG_LABEL}"
}

# Prints one line for everything that marks this Mac as having an agent. The identity
# (/etc/liongard-agent) and the script logs are never leftovers.
lg_agent_leftovers() {
    local label receipt
    for label in ${LG_LABELS}; do
        if launchctl print "system/${label}" >/dev/null 2>&1; then echo "loaded service system/${label}"; fi
        if [ -e "${LG_DAEMON_DIR}/${label}.plist" ] || [ -L "${LG_DAEMON_DIR}/${label}.plist" ]; then echo "${LG_DAEMON_DIR}/${label}.plist"; fi
    done
    if pgrep -f "^${LG_AGENT_DIR}/" >/dev/null 2>&1; then echo "processes running from ${LG_AGENT_DIR}"; fi
    if [ -e "${LG_AGENT_DIR}" ] || [ -L "${LG_AGENT_DIR}" ]; then echo "folder ${LG_AGENT_DIR}"; fi
    for receipt in ${LG_RECEIPTS}; do
        if pkgutil --pkg-info "${receipt}" >/dev/null 2>&1; then echo "package receipt ${receipt}"; fi
    done
    return 0
}

# Usage: lg_install_state [clean]. Sets LG_STATE to Healthy, Stale or NotInstalled. Healthy means the
# LaunchDaemon, binary and config exist and the agent is running; "clean" also counts a refused agent as Stale.
lg_install_state() {
    local plist=false binary=false config=false running=false rejected=false leftovers line
    if [ -f "${LG_DAEMON_DIR}/${LG_LABEL}.plist" ]; then plist=true; fi
    if [ -x "${LG_AGENT_BINARY}" ]; then binary=true; fi
    if [ -f "${LG_AGENT_CONFIG}" ]; then config=true; fi
    if lg_launchd_running "${LG_LABEL}"; then running=true; fi
    if [ "$1" = clean ] && lg_heartbeat_rejected "${LG_AGENT_LOG}"; then rejected=true; fi
    leftovers="$(lg_agent_leftovers)"
    log_info "LaunchDaemon ${LG_LABEL}: ${plist}; running: ${running}"
    log_info "Agent binary ${LG_AGENT_BINARY}: ${binary}; agent config ${LG_AGENT_CONFIG}: ${config}"
    if [ "$1" = clean ]; then log_info "Platform refused the last 3 heartbeats (HTTP 401 in ${LG_AGENT_LOG}): ${rejected}"; fi
    while IFS= read -r line; do
        if [ -n "${line}" ]; then log_info "  Found: ${line}"; fi
    done <<< "${leftovers}"
    if [ "${plist}" = true ] && [ "${binary}" = true ] && [ "${config}" = true ] && [ "${running}" = true ] && [ "${rejected}" = false ]; then
        LG_STATE=Healthy
    elif [ -z "${leftovers}" ]; then
        LG_STATE=NotInstalled
    else
        LG_STATE=Stale
    fi
    log_info "Install state: ${LG_STATE}"
}

lg_updating() {
    lg_launchd_running "${LG_UPDATER_LABEL}"
}

# Clean install only: waits for a running update, then gives a stopped agent one start attempt.
lg_prepare_existing_agent() {
    local i=0
    if lg_service_running; then return 0; fi
    if lg_updating; then
        log_info "The agent is not running and its updater is running; waiting up to 2 minutes."
        while lg_updating && [ "${i}" -lt 12 ]; do sleep 10; i=$((i + 1)); done
        if lg_updating; then lg_exit "${EXIT_BUSY}" "An agent update is still running after 2 minutes. Nothing was changed; run the script again later."; fi
    fi
    if [ -f "${LG_DAEMON_DIR}/${LG_LABEL}.plist" ] && [ -x "${LG_AGENT_BINARY}" ] && [ -f "${LG_AGENT_CONFIG}" ]; then
        log_info "The agent is not running; trying to start it once."
        if ! launchctl print "system/${LG_LABEL}" >/dev/null 2>&1; then
            launchctl bootstrap system "${LG_DAEMON_DIR}/${LG_LABEL}.plist" >/dev/null 2>&1
        fi
        launchctl kickstart "system/${LG_LABEL}" >/dev/null 2>&1
        i=0
        while ! lg_service_running && [ "${i}" -lt 6 ]; do sleep 5; i=$((i + 1)); done
    fi
    return 0
}

# The installed version: AGENT_VERSION from the config, or the binary's built-in version when that is higher.
lg_installed_version() {
    local v b
    v="$(lg_config_value AGENT_VERSION | tr -d '[:space:]')"
    lg_version_valid "${v}" || return 0
    if [ -f "${LG_AGENT_BINARY}" ]; then
        b="$(LC_ALL=C grep -a -o -E '[^A-Za-z]Version.default:"[0-9]+(\.[0-9]+)*"' "${LG_AGENT_BINARY}" 2>/dev/null |
            sed -n 's/.*default:"\([0-9.]*\)"$/\1/p' | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n | tail -1)"
        if lg_version_valid "${b}" && lg_version_newer "${b}" "${v}"; then v="${b}"; fi
    fi
    printf '%s' "${v}"
}

# The agent version from the package's postinstall; the Distribution and PackageInfo versions aren't it.
lg_package_version() {
    local component v
    component="$(sed -n 's/.*<pkg-ref[^>]*>#\([A-Za-z0-9._-]*\.pkg\)<\/pkg-ref>.*/\1/p' "${LG_WORK_DIR}/Distribution" | head -1)"
    if [ -n "${component}" ] && xar -xf "${LG_PKG}" -C "${LG_WORK_DIR}" "${component}/Scripts" 2>/dev/null; then
        v="$(tar -xOf "${LG_WORK_DIR}/${component}/Scripts" ./postinstall 2>/dev/null | sed -n 's/^VERSION="\([^"]*\)".*/\1/p' | head -1)"
    fi
    if lg_version_valid "${v}"; then printf '%s' "${v}"; fi
}

# Sets AGENT_VERSION in the agent config after an upgrade, as the agent's own updater does.
lg_set_config_version() {
    local tmp
    tmp="$(mktemp "${LG_AGENT_CONFIG}.XXXXXXXX")" || return 1
    if sed 's/\("AGENT_VERSION"[[:space:]]*:[[:space:]]*"\)[^"]*"/\1'"$1"'"/' "${LG_AGENT_CONFIG}" > "${tmp}" &&
        chown root:wheel "${tmp}" && chmod 600 "${tmp}" && mv -f "${tmp}" "${LG_AGENT_CONFIG}" &&
        [ "$(lg_config_value AGENT_VERSION)" = "$1" ]; then
        return 0
    fi
    rm -f "${tmp}"
    return 1
}

_lg_set_identity() {
    if [ -z "${LG_ID_VALUE}" ]; then LG_ID_VALUE="$1"; LG_ID_SOURCE="$2"; fi
}

# Collects every local identifier. The identity to save follows the package's tier order
# (resolveMachineGuid in installers/pkg/LiongardMacAgent/clearArgs.sh).
lg_collect_identity() {
    local value
    LG_ID_AGENT_ID="$(lg_config_value AGENT_ID | tr -d '[:space:]')"
    LG_ID_AGENT="" LG_ID_OS="" LG_ID_VALUE="" LG_ID_SOURCE="" LG_ID_LEGACY=false
    if [ -f "${LG_GUID_FILE}" ]; then
        value="$(tr -d '[:space:]' < "${LG_GUID_FILE}" 2>/dev/null)"
        if [[ "${value}" =~ ${LG_MACHINE_GUID_PATTERN} ]]; then
            lg_id_add LG_ID_AGENT guid-file "${value}"
            _lg_set_identity "${value}" tier1-machine-guid-file
        elif [ -n "${value}" ]; then
            log_warn "Ignoring the invalid identity in ${LG_GUID_FILE} (the package ignores it too)."
        fi
    fi
    value="$(lg_config_value MACHINE_GUID | tr -d '[:space:]')"
    if [[ "${value}" =~ ${LG_MACHINE_GUID_PATTERN} ]]; then
        lg_id_add LG_ID_AGENT config "${value}"
        _lg_set_identity "${value}" tier2-config-machine-guid
    elif [ -f "${LG_AGENT_CONFIG}" ]; then
        LG_ID_LEGACY=true
    fi
    value="$(ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null | awk -F'"' '/IOPlatformUUID/ {print $4}' | tr -d '[:space:]')"
    if [[ "${value}" =~ ${LG_MACHINE_GUID_PATTERN} ]]; then
        lg_id_add LG_ID_OS ioplatformuuid "${value}"
        if [ -f "${LG_AGENT_CONFIG}" ] && [ -z "${LG_ID_VALUE}" ]; then
            _lg_set_identity "${value}" tier3-ioplatformuuid
            LG_ID_LEGACY=true
        fi
    fi
    if [ -n "${LG_ID_VALUE}" ] && lg_is_junk_id "${LG_ID_VALUE}"; then
        log_warn "The agent identity [${LG_ID_VALUE}] is a placeholder value; it is saved but never used to find a platform record."
    fi
    log_info "Local AgentID: ${LG_ID_AGENT_ID:-none}"
    log_info "Agent identifiers: $(lg_values "${LG_ID_AGENT}" | tr '\n' ' ')"
    log_info "OS identifiers: $(lg_values "${LG_ID_OS}" | tr '\n' ' ')"
}

# Saves the identity (never the config: it holds the agent secret) in the LGAgentIdentity-macOS.sh
# backup format, so `LGAgentIdentity-macOS.sh restore --from <folder>` can use it.
lg_save_identity_backup() {
    local host stamp dest
    if [ -z "${LG_ID_VALUE}" ]; then
        if [ -f "${LG_AGENT_CONFIG}" ]; then
            lg_exit "${EXIT_IDENTITY}" "${LG_AGENT_CONFIG} exists but no agent identity could be resolved, so it can't be saved. Nothing was removed."
        fi
        log_info "No agent identity found on this Mac; nothing to save."
        return 0
    fi
    host="$(hostname -s)"
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    dest="${1%/}/liongard-identity-${host}-${stamp}"
    if [ -e "${dest}" ]; then
        lg_exit "${EXIT_IDENTITY}" "${dest} already exists. Nothing was removed."
    fi
    if ! ( umask 077 && mkdir -m 700 "${dest}" \
           && printf '%s\n' "${LG_ID_VALUE}" > "${dest}/machine-guid" \
           && {
                echo "format_version=1"
                echo "os=macos"
                echo "hostname=${host}"
                echo "created_utc=${stamp}"
                echo "identity_source=${LG_ID_SOURCE}"
                echo "legacy_identity=${LG_ID_LEGACY}"
                echo "agent_id=${LG_ID_AGENT_ID}"
                echo "agent_name=$(lg_config_value AGENT_NAME)"
                echo "agent_uid=$(lg_config_value AGENT_UID)"
                echo "url=$(lg_config_value URL)"
                echo "agent_version=$(lg_config_value AGENT_VERSION)"
                echo "config_included=false"
                echo "sha256_machine_guid=$(shasum -a 256 "${dest}/machine-guid" | awk '{print $1}')"
              } > "${dest}/manifest.txt" \
           && chmod 600 "${dest}/machine-guid" "${dest}/manifest.txt" ); then
        rm -rf "${dest}"
        lg_exit "${EXIT_IDENTITY}" "Could not write the agent identity backup to ${dest}. Nothing was removed."
    fi
    log_ok "Agent identity saved to ${dest} (identity ${LG_ID_VALUE}, source ${LG_ID_SOURCE}, AgentID ${LG_ID_AGENT_ID:-unknown}). It holds no key or secret."
    if [ "${LG_ID_LEGACY}" = true ]; then
        log_warn "This agent's config has no MACHINE_GUID, so the identity alone may not re-attach it to its record."
    fi
}

# Clean install: an identity that lived only in the agent config is written to the identity file
# before the config is removed, so the reinstall keeps it.
lg_seed_identity() {
    local tmp
    if [ "${LG_ID_SOURCE}" != tier2-config-machine-guid ] || [ -e "${LG_GUID_FILE}" ]; then return 0; fi
    if ! { mkdir -p "${LG_GUID_DIR}" && chmod 700 "${LG_GUID_DIR}" && tmp="$(mktemp "${LG_GUID_DIR}/.machine-guid.XXXXXXXX")"; }; then
        lg_exit "${EXIT_IDENTITY}" "Could not write ${LG_GUID_FILE}. The agent was removed but not reinstalled; restore the identity with LGAgentIdentity-macOS.sh."
    fi
    if ! { printf '%s\n' "${LG_ID_VALUE}" > "${tmp}" && chmod 600 "${tmp}" && mv -f "${tmp}" "${LG_GUID_FILE}"; }; then
        rm -f "${tmp}"
        lg_exit "${EXIT_IDENTITY}" "Could not write ${LG_GUID_FILE}. The agent was removed but not reinstalled; restore the identity with LGAgentIdentity-macOS.sh."
    fi
    log_info "Wrote the saved identity to ${LG_GUID_FILE}, so the reinstalled agent keeps it."
}

# True when the group or other users can write to the path, or its mode can't be read.
lg_writable_by_others() {
    local mode
    mode="$(stat -f %Lp "$1" 2>/dev/null)" || return 0
    [ $(( 8#${mode} & 8#022 )) -ne 0 ]
}

# Runs the package's uninstall.sh when root owns it, then stops and removes both LaunchDaemons,
# leftover processes, /Library/Liongard and the receipts. Keeps /etc/liongard-agent (identity).
lg_remove_local_agent() {
    local label receipt
    log_step "Removing the Liongard Agent from this Mac."
    if [ -e "${LG_PKG_UNINSTALL}" ]; then
        if [ -L "${LG_AGENT_DIR}" ] || [ ! -O "${LG_AGENT_DIR}" ] || lg_writable_by_others "${LG_AGENT_DIR}" \
            || [ ! -f "${LG_PKG_UNINSTALL}" ] || [ -L "${LG_PKG_UNINSTALL}" ] || [ ! -O "${LG_PKG_UNINSTALL}" ] || lg_writable_by_others "${LG_PKG_UNINSTALL}"; then
            log_warn "${LG_PKG_UNINSTALL} is not a root-owned file that only root can change, so it was not run."
        else
            log_info "Running ${LG_PKG_UNINSTALL}."
            /bin/zsh "${LG_PKG_UNINSTALL}" < /dev/null >/dev/null 2>&1
            log_info "${LG_PKG_UNINSTALL} exited with $?. Completing the removal."
        fi
    fi
    for label in ${LG_LABELS}; do
        if launchctl print "system/${label}" >/dev/null 2>&1; then
            log_info "Stopping system/${label}."
            launchctl bootout "system/${label}" >/dev/null 2>&1 || launchctl unload -w "${LG_DAEMON_DIR}/${label}.plist" >/dev/null 2>&1 || log_warn "Could not stop system/${label}."
        fi
        if [ -e "${LG_DAEMON_DIR}/${label}.plist" ] || [ -L "${LG_DAEMON_DIR}/${label}.plist" ]; then
            rm -f "${LG_DAEMON_DIR}/${label}.plist" || log_warn "Could not remove /Library/LaunchDaemons/${label}.plist."
        fi
    done
    if pkill -f "^${LG_AGENT_DIR}/" >/dev/null 2>&1; then
        log_info "Stopped processes running from ${LG_AGENT_DIR}."
        sleep 2
        pkill -9 -f "^${LG_AGENT_DIR}/" >/dev/null 2>&1
    fi
    if [ -e "${LG_AGENT_DIR}" ] || [ -L "${LG_AGENT_DIR}" ]; then
        rm -rf "${LG_AGENT_DIR}" || log_warn "Could not remove ${LG_AGENT_DIR}."
    fi
    for receipt in ${LG_RECEIPTS}; do
        if pkgutil --pkg-info "${receipt}" >/dev/null 2>&1; then
            log_info "Forgetting package receipt ${receipt}."
            pkgutil --forget "${receipt}" >/dev/null 2>&1 || log_warn "Could not forget the package receipt ${receipt}."
        fi
    done
}

# The names this Mac can be registered under. No truncated variants; "localhost" is never used.
lg_local_hostnames() {
    local seen=" " n lc
    for n in "$(hostname 2>/dev/null)" "$(hostname -s 2>/dev/null)" "$(scutil --get LocalHostName 2>/dev/null)"; do
        n="${n%.}"
        lc="$(printf '%s' "${n}" | tr '[:upper:]' '[:lower:]')"
        if [ -z "${n}" ] || [ "${lc}" = localhost ] || [[ "${seen}" == *" ${lc} "* ]]; then continue; fi
        seen="${seen}${lc} "
        printf '%s\n' "${n}"
    done
}

# Refuses symlinks and files not owned by root, then deletes the file.
lg_remove_checked() {
    if [ -L "$1" ]; then lg_exit "${EXIT_PREREQUISITE}" "$1 is a symlink. Refusing to continue; investigate and remove it as root."; fi
    if [ -e "$1" ] && [ ! -O "$1" ]; then lg_exit "${EXIT_PREREQUISITE}" "$1 exists and is not owned by root. Refusing to continue; investigate and remove it as root."; fi
    if ! rm -f "$1" || [ -e "$1" ]; then lg_exit "${EXIT_PREREQUISITE}" "Could not remove existing $1."; fi
}

# Writes $1 to a new root-only temp file, then renames it onto $2; rename(2) replaces a planted symlink.
lg_write() {
    if [ -e "$2" ] || [ -L "$2" ]; then lg_exit "${EXIT_PREREQUISITE}" "$2 appeared after the pre-run cleanup. Refusing to continue."; fi
    LG_TMP="$(mktemp /tmp/liongard.XXXXXXXX)" || lg_exit "${EXIT_PREREQUISITE}" "mktemp failed."
    if ! printf '%s\n' "$1" > "${LG_TMP}" || ! chown root:wheel "${LG_TMP}" || ! chmod 600 "${LG_TMP}" || ! mv -f "${LG_TMP}" "$2"; then
        lg_exit "${EXIT_PREREQUISITE}" "Could not write $2."
    fi
    LG_TMP=""
    if [ -L "$2" ] || [ ! -f "$2" ] || [ ! -O "$2" ]; then lg_exit "${EXIT_PREREQUISITE}" "$2 is not a root-owned regular file after writing."; fi
}

lg_cleanup() {
    local f
    if [ -n "${LG_TMP}" ]; then rm -f "${LG_TMP}"; fi
    for f in ${LG_HANDOFF_FILES}; do rm -f "${f}"; done
    if [ -n "${LG_WORK_DIR}" ]; then rm -rf "${LG_WORK_DIR}"; fi
}

# Clears the package handoff files and the installer UI's values file before a run.
lg_clear_handoff() {
    local f
    for f in ${LG_HANDOFF_FILES}; do lg_remove_checked "${f}"; done
    if [ -e "${LG_VALUES_FILE}" ] || [ -L "${LG_VALUES_FILE}" ]; then
        log_info "Removing ${LG_VALUES_FILE} left by an earlier install."
        if ! rm -f "${LG_VALUES_FILE}" || [ -e "${LG_VALUES_FILE}" ] || [ -L "${LG_VALUES_FILE}" ]; then lg_exit "${EXIT_PREREQUISITE}" "Could not remove ${LG_VALUES_FILE}."; fi
    fi
    if [ -e "${LG_PKG_LOG}" ] && [ ! -L "${LG_PKG_LOG}" ] && [ -f "${LG_PKG_LOG}" ] && [ -O "${LG_PKG_LOG}" ]; then
        chmod 600 "${LG_PKG_LOG}" || lg_exit "${EXIT_PREREQUISITE}" "Could not restrict ${LG_PKG_LOG}."
    else
        lg_remove_checked "${LG_PKG_LOG}"
        lg_write "" "${LG_PKG_LOG}"
    fi
}

# Downloads (or copies PKG_PATH) and checks size, Liongard signature and CPU architecture. Sets LG_PKG.
lg_fetch_package() {
    local arch url attempt=1 expected actual size signature host_architectures
    if [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = "1" ]; then LG_HOST_ARCH=arm64; else LG_HOST_ARCH=x64; fi
    case "${MAC_ARCHITECTURE}" in
        auto) arch="${LG_HOST_ARCH}" ;;
        x64|arm64) arch="${MAC_ARCHITECTURE}" ;;
        *) lg_exit "${EXIT_CONFIG}" "MAC_ARCHITECTURE must be auto, x64 or arm64 (got '${MAC_ARCHITECTURE}')." ;;
    esac
    if [ "${LG_HOST_ARCH}" = x64 ] && [ "${arch}" = arm64 ]; then lg_exit "${EXIT_CONFIG}" "MAC_ARCHITECTURE=arm64 can't be installed on an Intel Mac."; fi
    LG_PKG="${LG_WORK_DIR}/LiongardAgent.pkg"
    if [ -n "${PKG_PATH}" ]; then
        if [ ! -f "${PKG_PATH}" ]; then lg_exit "${EXIT_CONFIG}" "PKG_PATH '${PKG_PATH}' is not a file."; fi
        # Copied first, so the file that's checked is the file that's installed.
        log_info "Using the local package ${PKG_PATH}."
        cp "${PKG_PATH}" "${LG_PKG}" || lg_exit "${EXIT_DOWNLOAD}" "Could not copy ${PKG_PATH}."
    else
        if [ "${arch}" = arm64 ]; then url="${LG_PKG_URL_ARM64}"; else url="${LG_PKG_URL_X64}"; fi
        log_info "Downloading ${url}."
        while :; do
            expected="$(curl -sSfIL --connect-timeout 30 "${url}" 2>/dev/null | tr -d '\r' | awk 'tolower($1)=="content-length:"{v=$2} END{print v}')"
            if curl -sSfL --connect-timeout 30 --retry 2 --retry-delay 5 -o "${LG_PKG}" "${url}"; then
                actual="$(stat -f%z "${LG_PKG}" 2>/dev/null)"
                if [ -z "${expected}" ] || [ "${actual}" = "${expected}" ]; then break; fi
                log_warn "Downloaded ${actual} bytes, expected ${expected} (attempt ${attempt})."
            else
                log_warn "Download failed (attempt ${attempt})."
            fi
            if [ "${attempt}" -ge 3 ]; then lg_exit "${EXIT_DOWNLOAD}" "Could not download ${url} after 3 attempts. Nothing was changed."; fi
            attempt=$((attempt + 1))
            sleep 10
        done
    fi
    size="$(stat -f%z "${LG_PKG}" 2>/dev/null)"
    if [ -z "${size}" ] || [ "${size}" -lt "${LG_PKG_MIN_BYTES}" ]; then
        lg_exit "${EXIT_DOWNLOAD}" "The package is ${size:-0} bytes, smaller than expected. Nothing was changed."
    fi
    if ! signature="$(pkgutil --check-signature "${LG_PKG}" 2>&1)" || ! printf '%s\n' "${signature}" | grep -q "^ *1\. Developer ID Installer: .*(${LG_PKG_TEAM_ID})$"; then
        log_error "${signature}"
        lg_exit "${EXIT_DOWNLOAD}" "The package is not signed by Liongard (Team ID ${LG_PKG_TEAM_ID}). Nothing was changed."
    fi
    log_info "Package signature: Developer ID Installer, Team ID ${LG_PKG_TEAM_ID}."
    xar -xf "${LG_PKG}" -C "${LG_WORK_DIR}" Distribution 2>/dev/null || lg_exit "${EXIT_DOWNLOAD}" "Could not read the package's Distribution file."
    host_architectures="$(sed -n 's/.*hostArchitectures="\([^"]*\)".*/\1/p' "${LG_WORK_DIR}/Distribution" | head -1)"
    log_info "Package architecture: ${host_architectures:-not set}. This Mac: ${LG_HOST_ARCH}."
    if [ -n "${host_architectures}" ]; then
        case ",${host_architectures}," in
            *,x86_64,*) ;;
            *) if [ "${LG_HOST_ARCH}" = x64 ]; then lg_exit "${EXIT_DOWNLOAD}" "This package is for Apple Silicon and can't be installed on an Intel Mac."; fi ;;
        esac
    fi
    LG_PKG_VERSION="$(lg_package_version)"
    log_info "Package version: ${LG_PKG_VERSION:-unreadable}."
}

# Installs Rosetta 2 when the Intel-only package is used on Apple Silicon.
lg_ensure_rosetta() {
    local host_architectures
    host_architectures="$(sed -n 's/.*hostArchitectures="\([^"]*\)".*/\1/p' "${LG_WORK_DIR}/Distribution" | head -1)"
    if [ "${LG_HOST_ARCH}" != arm64 ] || [ -z "${host_architectures}" ]; then return 0; fi
    case ",${host_architectures}," in *,arm64,*) return 0 ;; esac
    if arch -x86_64 /usr/bin/true >/dev/null 2>&1; then
        log_info "This is the Intel package; Rosetta 2 is already installed."
        return 0
    fi
    log_info "This is the Intel package; installing Rosetta 2."
    if ! softwareupdate --install-rosetta --agree-to-license >/dev/null 2>&1 || ! arch -x86_64 /usr/bin/true >/dev/null 2>&1; then
        lg_exit "${EXIT_PREREQUISITE}" "Could not install Rosetta 2."
    fi
}

# True when the agent runs (waits up to 30 seconds) and the updater LaunchDaemon is installed.
lg_validate_install() {
    local i=0 updater=false
    while ! lg_service_running && [ "${i}" -lt 15 ]; do sleep 2; i=$((i + 1)); done
    if [ -f "${LG_DAEMON_DIR}/${LG_UPDATER_LABEL}.plist" ]; then updater=true; fi
    log_info "Validation: ${LG_LABEL} running: $(lg_service_running && echo true || echo false); updater LaunchDaemon: ${updater}"
    lg_service_running && [ "${updater}" = true ]
}

# Usage: lg_install_main <simple|advanced|clean>
lg_install_main() {
    local mode="$1" installed="" leftovers line status upgrade=false
    lg_require_root
    umask 077
    lg_start_log "${LOG_DIRECTORY:-/Library/Logs/LiongardDeploy}" LGAgentScript
    lg_add_secret "${ACCESS_KEY_ID}"
    lg_add_secret "${ACCESS_KEY_SECRET}"
    lg_add_secret "${API_TOKEN_KEY:-}"
    lg_add_secret "${API_TOKEN_SECRET:-}"
    log_step "Liongard Agent ${mode} install on $(hostname -s 2>/dev/null)."

    lg_require INSTANCE_URL "${INSTANCE_URL}"
    lg_require ACCESS_KEY_ID "${ACCESS_KEY_ID}"
    lg_require ACCESS_KEY_SECRET "${ACCESS_KEY_SECRET}"
    lg_require_bool INCLUDE_ENVIRONMENT_VALUE "${INCLUDE_ENVIRONMENT_VALUE}"
    if [ "${INCLUDE_ENVIRONMENT_VALUE}" = true ]; then lg_require ENVIRONMENT "${ENVIRONMENT}"; fi
    for line in NAME AGENT_DESCRIPTION; do
        case "$(eval "printf '%s' \"\${${line}}\"")" in REPLACE_WITH_*) lg_exit "${EXIT_CONFIG}" "Configuration value [${line}] is still a placeholder; set it or leave it blank." ;; esac
    done
    if [ "${mode}" = advanced ]; then
        lg_require API_TOKEN_KEY "${API_TOKEN_KEY}"
        lg_require API_TOKEN_SECRET "${API_TOKEN_SECRET}"
        if ! command -v jq >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then lg_exit "${EXIT_PREREQUISITE}" "curl and jq are required for the environment check. recent macOS ships /usr/bin/jq."; fi
    fi
    LG_INSTALL_HOST="$(lg_instance_host "${INSTANCE_URL}")" || lg_exit "${EXIT_CONFIG}" "INSTANCE_URL '${INSTANCE_URL}' is not a Liongard instance such as us1.app.liongard.com or us1."
    log_info "Instance ${LG_INSTALL_HOST}; agent name ${NAME:-(hostname)}; environment ${ENVIRONMENT} (sent: ${INCLUDE_ENVIRONMENT_VALUE}); description ${AGENT_DESCRIPTION:-(none)}; architecture ${MAC_ARCHITECTURE}; package path ${PKG_PATH:-(download)}"

    if [ "${mode}" = clean ]; then lg_prepare_existing_agent; fi
    lg_install_state "${mode}"
    if [ "${LG_STATE}" = Stale ] && [ "${mode}" != clean ]; then
        lg_exit "${EXIT_STALE}" "The installed agent is broken or not running (Stale). Nothing was changed. Run LGAgentCleanInstall-macOS-Simple.sh to repair it."
    fi

    LG_INSTALL_ENVIRONMENT=""
    if [ "${INCLUDE_ENVIRONMENT_VALUE}" = true ]; then
        LG_INSTALL_ENVIRONMENT="${ENVIRONMENT}"
        if [ "${mode}" = advanced ]; then
            lg_api_setup "${LG_INSTALL_HOST}" "${API_TOKEN_KEY}" "${API_TOKEN_SECRET}"
            lg_resolve_environment "${ENVIRONMENT}" || lg_exit "${EXIT_ENVIRONMENT}" "The environment check failed (${LG_ENV_REASON}). Nothing was changed."
            LG_INSTALL_ENVIRONMENT="${LG_ENV_NAME}"
        fi
    fi

    lg_clear_handoff
    trap 'lg_cleanup' EXIT
    trap 'lg_cleanup; trap - EXIT; exit 130' INT
    trap 'lg_cleanup; trap - EXIT; exit 143' TERM
    LG_WORK_DIR="$(mktemp -d /tmp/liongard-pkg.XXXXXXXX)" || lg_exit "${EXIT_PREREQUISITE}" "Could not create a private download folder."
    lg_fetch_package

    if [ "${LG_STATE}" = Healthy ]; then
        installed="$(lg_installed_version)"
        log_info "Installed agent version: ${installed:-unreadable}; package version: ${LG_PKG_VERSION:-unreadable}."
        if [ -z "${installed}" ] || [ -z "${LG_PKG_VERSION}" ]; then
            lg_exit "${EXIT_DOWNLOAD}" "The versions can't be compared, so the agent was not upgraded. Nothing was changed."
        fi
        if ! lg_version_newer "${LG_PKG_VERSION}" "${installed}"; then
            lg_exit "${EXIT_OK}" "Liongard Agent ${installed} is installed and running, and the package (${LG_PKG_VERSION}) is not newer. Nothing to do."
        fi
        log_info "Upgrading the agent from ${installed} to ${LG_PKG_VERSION}. It keeps its registration."
        upgrade=true
    elif [ "${mode}" = clean ]; then
        lg_collect_identity
        lg_save_identity_backup "${LOG_DIRECTORY:-/Library/Logs/LiongardDeploy}"
        if [ "${LG_STATE}" = Stale ]; then
            lg_remove_local_agent
            leftovers="$(lg_agent_leftovers)"
            if [ -n "${leftovers}" ]; then
                while IFS= read -r line; do log_error "  Still present: ${line}"; done <<< "${leftovers}"
                lg_exit "${EXIT_REMOVAL}" "The broken agent could not be removed completely, so it was not reinstalled."
            fi
            lg_seed_identity
        fi
    fi
    lg_ensure_rosetta

    # An upgrade keeps the existing registration, so it writes no handoff files.
    if [ "${upgrade}" = false ]; then
        lg_write "${LG_INSTALL_HOST}" /tmp/liongard_instance_url
        lg_write "${ACCESS_KEY_ID}" /tmp/liongard_access_key_id
        lg_write "${ACCESS_KEY_SECRET}" /tmp/liongard_access_key_secret
        if [ -n "${NAME}" ]; then lg_write "${NAME}" /tmp/liongard_name; fi
        if [ -n "${LG_INSTALL_ENVIRONMENT}" ]; then lg_write "${LG_INSTALL_ENVIRONMENT}" /tmp/liongard_environment; fi
        if [ -n "${AGENT_DESCRIPTION}" ]; then lg_write "${AGENT_DESCRIPTION}" /tmp/liongard_description; fi
    fi
    if [ -e "${LG_VALUES_FILE}" ] || [ -L "${LG_VALUES_FILE}" ]; then lg_exit "${EXIT_PREREQUISITE}" "${LG_VALUES_FILE} appeared during the run. Refusing to continue."; fi

    log_step "Running the installer."
    installer -pkg "${LG_PKG}" -target / > "${LG_WORK_DIR}/installer-output" 2>&1
    status=$?
    while IFS= read -r line; do log_info "installer: ${line}"; done < "${LG_WORK_DIR}/installer-output"
    if [ "${status}" -ne 0 ]; then
        lg_exit "${EXIT_INSTALLER}" "The installer exited with ${status}. See ${LG_PKG_LOG} and /var/log/install.log."
    fi
    # The package leaves a running agent on the old binary and keeps AGENT_VERSION, so an upgrade
    # records the new version and restarts the agent, as the agent's own updater does.
    if [ "${upgrade}" = true ]; then
        lg_set_config_version "${LG_PKG_VERSION}" || log_warn "Could not set AGENT_VERSION to ${LG_PKG_VERSION} in ${LG_AGENT_CONFIG}; the next run installs the package again."
        launchctl kickstart -k "system/${LG_LABEL}" >/dev/null 2>&1 || lg_exit "${EXIT_VALIDATION}" "The upgrade was installed, but the agent could not be restarted (system/${LG_LABEL})."
    fi
    lg_validate_install || lg_exit "${EXIT_VALIDATION}" "The installer finished, but the agent is not running or the updater LaunchDaemon is missing."
    lg_exit "${EXIT_OK}" "The Liongard Agent is installed and running (version $(lg_config_value AGENT_VERSION))."
}

# Usage: lg_uninstall_main <simple|advanced>
lg_uninstall_main() {
    local mode="$1" leftovers line rc f
    local -a names=()
    lg_require_root
    umask 077
    lg_start_log "${LOG_DIRECTORY:-/Library/Logs/LiongardDeploy}" LGAgentUninstall
    if [ "${mode}" = advanced ]; then lg_check_platform_settings; fi
    lg_collect_identity
    lg_save_identity_backup "${LOG_DIRECTORY:-/Library/Logs/LiongardDeploy}"
    leftovers="$(lg_agent_leftovers)"
    if [ -z "${leftovers}" ]; then
        log_info "No Liongard Agent found on this Mac. Nothing to remove locally."
    else
        while IFS= read -r line; do log_info "  Found: ${line}"; done <<< "${leftovers}"
        lg_remove_local_agent
        leftovers="$(lg_agent_leftovers)"
        if [ -n "${leftovers}" ]; then
            while IFS= read -r line; do log_error "  Still present: ${line}"; done <<< "${leftovers}"
            lg_exit "${EXIT_REMOVAL}" "The Liongard Agent is still detected after the removal. The platform record was not touched."
        fi
        log_ok "The Liongard Agent is removed from this Mac."
    fi
    for f in ${LG_HANDOFF_FILES} "${LG_VALUES_FILE}"; do
        if [ -e "${f}" ] || [ -L "${f}" ]; then rm -f "${f}" || log_warn "Could not remove ${f}."; fi
    done
    if [ -f "${LG_GUID_FILE}" ]; then log_info "Agent identity ${LG_GUID_FILE} kept, so a reinstall re-attaches to the same record."; fi
    if [ "${mode}" = advanced ] && [ "${REMOVE_AGENT_FROM_PLATFORM}" = true ]; then
        while IFS= read -r line; do if [ -n "${line}" ]; then names+=("${line}"); fi; done <<< "$(lg_local_hostnames)"
        rc=0
        lg_remove_platform_record "${ENVIRONMENT}" ${names[@]+"${names[@]}"} || rc=$?
        case "${rc}" in
            0) ;;
            2) log_warn "No platform record qualified; nothing was deleted. It may already be gone." ;;
            *) lg_exit "${EXIT_PLATFORM}" "The platform record was not removed (see above). The agent was removed from this Mac." ;;
        esac
    fi
    lg_exit "${EXIT_OK}" "Uninstall finished."
}

# END SHARED BLOCK: Liongard macOS agent functions

lg_install_main clean
