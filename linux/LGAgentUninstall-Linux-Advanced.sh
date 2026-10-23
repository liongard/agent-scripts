#!/usr/bin/env bash
#
# SYNOPSIS
#   Removes the Liongard Agent from this Linux machine and, optionally, its platform record.
#
# DESCRIPTION
#   Set your values in the configuration block below. Exit codes, logs and troubleshooting are in
#   the README under LINK.
#   - Does everything LGAgentUninstall-Linux-Simple.sh does.
#   - REMOVE_AGENT_FROM_PLATFORM=true then deletes the platform record. It looks it up by
#     AgentID, then MachineGuid, then hostname, logs every candidate, and deletes only when
#     exactly one record qualifies. A failed lookup or delete exits 10.
#
# NOTES
#   Requires:     root, bash. curl, jq and a Liongard API token when REMOVE_AGENT_FROM_PLATFORM=true.
#   Author:       Liongard Partner Support
#   Last updated: 2026-10-23
#
# LINK
#   https://github.com/liongard/agent-scripts/blob/main/linux/README.md

# ------------------------------------------------------------
# CONFIGURATION
# ------------------------------------------------------------

# true also deletes the agent's platform record after the local removal succeeds.
REMOVE_AGENT_FROM_PLATFORM=false

# Required when REMOVE_AGENT_FROM_PLATFORM=true: the instance (us1 or us1.app.liongard.com)
# and a Liongard API token.
INSTANCE_PREFIX="REPLACE_WITH_INSTANCE_PREFIX"
API_TOKEN_KEY="REPLACE_WITH_API_TOKEN_KEY"
API_TOKEN_SECRET="REPLACE_WITH_API_TOKEN_SECRET"

# The environment the agent is registered in. Blank means the agent has no environment.
ENVIRONMENT=""

# Root-only folder for the script log and the identity backup.
LOG_DIRECTORY="/var/log/liongard-agent"

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

# BEGIN SHARED BLOCK: Liongard Linux agent functions
# Identical in every linux/LGAgent*.sh script except LGAgentIdentity-Linux.sh.

LG_AGENT_DIR="/opt/liongard"
LG_AGENT_BINARY="${LG_AGENT_DIR}/LiongardAgent"
LG_AGENT_CONFIG="${LG_AGENT_DIR}/.config"
LG_AGENT_LOG="${LG_AGENT_DIR}/logs/agent.log"
LG_GUID_DIR="/etc/liongard-agent"
LG_GUID_FILE="${LG_GUID_DIR}/.machine-guid"
LG_MACHINE_ID_FILES="/etc/machine-id /var/lib/dbus/machine-id"
LG_CORE_SERVICE="liongard-agent"
LG_UPDATER_SERVICE="liongard-agent-updater"
LG_LEGACY_SERVICES="roaragent liongardagent LiongardAgent"
LG_LEGACY_UPDATER_TIMERS="liongard-updater roaragent-updater"
LG_UNIT_DIRS="/etc/systemd/system /lib/systemd/system /usr/lib/systemd/system"
LG_AGENT_DIRS="/opt/liongard /opt/liongard-agent /usr/local/liongard /etc/liongard"
LG_LEGACY_BINARIES="/usr/local/bin/liongard-agent /usr/bin/liongard-agent /usr/local/bin/roaragent /usr/bin/roaragent /usr/local/bin/liongardagent /usr/bin/liongardagent"
LG_UNINSTALL_SCRIPTS="/opt/liongard/uninstall.sh /opt/liongard/uninstall /opt/liongard-agent/uninstall.sh /opt/liongard-agent/uninstall /usr/local/liongard/uninstall.sh /usr/local/liongard/uninstall"
LG_MACHINE_GUID_PATTERN='^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'
LG_MIN_INSTALLER_BYTES=10240
LG_STATE=""
LG_WORK_DIR=""
LG_INSTALLER_FILE=""
LG_INSTALLER_TYPE=""
LG_INSTALL_HOST=""
LG_INSTALL_ENVIRONMENT=""
LG_ID_VALUE=""
LG_ID_SOURCE=""
LG_ID_TIER=""

_lg_has() {
    command -v "$1" >/dev/null 2>&1
}

# Reads KEY from the agent config the way the installer does: split on the first '='.
lg_config_value() {
    [ -r "${LG_AGENT_CONFIG}" ] || return 0
    awk -v k="$1" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "${LG_AGENT_CONFIG}"
}

lg_unit_file() {
    local dir
    for dir in ${LG_UNIT_DIRS}; do
        if [ -f "${dir}/$1" ]; then printf '%s' "${dir}/$1"; return 0; fi
    done
    return 1
}

lg_service_running() {
    _lg_has systemctl && systemctl is-active --quiet "${LG_CORE_SERVICE}" 2>/dev/null
}

lg_deb_packages() {
    _lg_has dpkg-query || return 0
    dpkg-query -W -f='${Status} ${Package}\n' 2>/dev/null | awk '$3 == "installed" && tolower($4) ~ /liongard|roaragent/ { print $4 }'
}

lg_rpm_packages() {
    _lg_has rpm || return 0
    rpm -qa --qf '%{NAME}\n' 2>/dev/null | grep -Ei 'liongard|roaragent'
    return 0
}

# Prints one line for everything that marks this machine as having an agent. The identity
# (/etc/liongard-agent) and the script logs are never leftovers.
lg_agent_leftovers() {
    local name dir path
    for name in "${LG_CORE_SERVICE}.service" "${LG_UPDATER_SERVICE}.service" "${LG_UPDATER_SERVICE}.timer"; do
        path="$(lg_unit_file "${name}")" && echo "unit ${path}"
    done
    for name in ${LG_LEGACY_SERVICES}; do
        path="$(lg_unit_file "${name}.service")" && echo "unit ${path}"
    done
    for name in ${LG_LEGACY_UPDATER_TIMERS}; do
        path="$(lg_unit_file "${name}.timer")" && echo "unit ${path}"
    done
    if _lg_has pgrep && pgrep -f "^${LG_AGENT_DIR}/" >/dev/null 2>&1; then echo "processes running from ${LG_AGENT_DIR}"; fi
    for name in ${LG_LEGACY_SERVICES}; do
        if _lg_has pgrep && pgrep -x "${name}" >/dev/null 2>&1; then echo "process ${name}"; fi
    done
    for name in $(lg_deb_packages) $(lg_rpm_packages); do echo "package ${name}"; done
    for path in ${LG_LEGACY_BINARIES}; do
        if [ -e "${path}" ]; then echo "binary ${path}"; fi
    done
    for dir in ${LG_AGENT_DIRS}; do
        if [ -e "${dir}" ]; then echo "folder ${dir}"; fi
    done
    return 0
}

# Usage: lg_install_state [clean]. Sets LG_STATE to Healthy, Stale or NotInstalled. Healthy means the
# unit, binary and config exist and the service is running; "clean" also counts a refused agent as Stale.
lg_install_state() {
    local unit binary=false config=false running=false rejected=false leftovers line
    unit="$(lg_unit_file "${LG_CORE_SERVICE}.service")" || unit=""
    if [ -x "${LG_AGENT_BINARY}" ]; then binary=true; fi
    if [ -f "${LG_AGENT_CONFIG}" ]; then config=true; fi
    if lg_service_running; then running=true; fi
    if [ "$1" = clean ] && lg_heartbeat_rejected "${LG_AGENT_LOG}"; then rejected=true; fi
    leftovers="$(lg_agent_leftovers)"
    log_info "Service unit ${LG_CORE_SERVICE}: ${unit:-not registered}; running: ${running}"
    log_info "Agent binary ${LG_AGENT_BINARY}: ${binary}; agent config ${LG_AGENT_CONFIG}: ${config}"
    if [ "$1" = clean ]; then log_info "Platform refused the last 3 heartbeats (HTTP 401 in ${LG_AGENT_LOG}): ${rejected}"; fi
    while IFS= read -r line; do
        if [ -n "${line}" ]; then log_info "  Found: ${line}"; fi
    done <<< "${leftovers}"
    if [ -n "${unit}" ] && [ "${binary}" = true ] && [ "${config}" = true ] && [ "${running}" = true ] && [ "${rejected}" = false ]; then
        LG_STATE=Healthy
    elif [ -z "${leftovers}" ]; then
        LG_STATE=NotInstalled
    else
        LG_STATE=Stale
    fi
    log_info "Install state: ${LG_STATE}"
}

# True while the agent's updater runs; an install or cleanup now could break it.
lg_updating() {
    _lg_has systemctl || return 1
    case "$(systemctl is-active "${LG_UPDATER_SERVICE}.service" 2>/dev/null)" in
        active|activating|reloading) return 0 ;;
    esac
    return 1
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
    if lg_unit_file "${LG_CORE_SERVICE}.service" >/dev/null && [ -x "${LG_AGENT_BINARY}" ] && [ -f "${LG_AGENT_CONFIG}" ] && _lg_has systemctl; then
        log_info "The agent service is stopped; trying to start it once."
        systemctl start "${LG_CORE_SERVICE}" >/dev/null 2>&1
        i=0
        while ! lg_service_running && [ "${i}" -lt 6 ]; do sleep 5; i=$((i + 1)); done
    fi
    return 0
}

lg_installed_version() {
    local v
    v="$(lg_config_value AGENT_VERSION | tr -d '[:space:]')"
    if lg_version_valid "${v}"; then printf '%s' "${v}"; fi
}

# Reads the version of a downloaded installer without running its install step.
lg_installer_version() {
    local v=""
    case "${LG_INSTALLER_TYPE}" in
        sh)
            if sed -n 2p "$1" 2>/dev/null | grep -q '^# This script was generated using Makeself'; then
                v="$(sh "$1" --tar xOf ./version.txt 2>/dev/null | head -n 1 | tr -d '[:space:]')"
            fi ;;
        deb) if _lg_has dpkg-deb; then v="$(dpkg-deb -f "$1" Version 2>/dev/null | sed 's/[-~+].*//')"; fi ;;
        rpm) if _lg_has rpm; then v="$(rpm -qp --qf '%{VERSION}' "$1" 2>/dev/null)"; fi ;;
    esac
    if lg_version_valid "${v}"; then printf '%s' "${v}"; fi
}

_lg_set_identity() {
    if [ -z "${LG_ID_VALUE}" ]; then LG_ID_VALUE="$1"; LG_ID_SOURCE="$2"; LG_ID_TIER="$3"; fi
}

# Collects every local identifier. The identity to save follows the installer's tier order
# (resolveMachineGuid in installers/makeself/src/install.ts).
lg_collect_identity() {
    local value path
    LG_ID_AGENT_ID="$(lg_config_value AGENT_ID | tr -d '[:space:]')"
    LG_ID_AGENT="" LG_ID_OS="" LG_ID_VALUE="" LG_ID_SOURCE="" LG_ID_TIER=""
    if [ -f "${LG_GUID_FILE}" ]; then
        value="$(tr -d '[:space:]' < "${LG_GUID_FILE}" 2>/dev/null)"
        if [[ "${value}" =~ ${LG_MACHINE_GUID_PATTERN} ]]; then
            lg_id_add LG_ID_AGENT guid-file "${value}"
            _lg_set_identity "${value}" guid-file 1
        elif [ -n "${value}" ]; then
            log_warn "Ignoring the invalid identity in ${LG_GUID_FILE} (the installer ignores it too)."
        fi
    fi
    value="$(lg_config_value MACHINE_GUID | tr -d '[:space:]')"
    if [ -n "${value}" ]; then
        lg_id_add LG_ID_AGENT config "${value}"
        if [[ "${value}" =~ ${LG_MACHINE_GUID_PATTERN} ]]; then _lg_set_identity "${value}" config 2; else _lg_set_identity "${value}" config-nonstandard 2; fi
    fi
    for path in ${LG_MACHINE_ID_FILES}; do
        value="$(tr -d '[:space:]' < "${path}" 2>/dev/null)"
        [[ "${value}" =~ ${LG_MACHINE_GUID_PATTERN} ]] || continue
        lg_id_add LG_ID_OS "machine-id:${path}" "${value}"
        if [ -f "${LG_AGENT_CONFIG}" ]; then _lg_set_identity "${value}" machine-id 3; fi
    done
    if [ -n "${LG_ID_VALUE}" ] && lg_is_junk_id "${LG_ID_VALUE}"; then
        log_warn "The agent identity [${LG_ID_VALUE}] is a placeholder value; it is saved but never used to find a platform record."
    fi
    log_info "Local AgentID: ${LG_ID_AGENT_ID:-none}"
    log_info "Agent identifiers: $(lg_values "${LG_ID_AGENT}" | tr '\n' ' ')"
    log_info "OS identifiers: $(lg_values "${LG_ID_OS}" | tr '\n' ' ')"
}

# Saves the identity (never the config: it holds the agent secret) in the LGAgentIdentity-Linux.sh
# backup format, so `LGAgentIdentity-Linux.sh restore --from <folder>` can use it.
lg_save_identity_backup() {
    local host created dest
    if [ -z "${LG_ID_VALUE}" ]; then
        if [ -f "${LG_AGENT_CONFIG}" ]; then
            lg_exit "${EXIT_IDENTITY}" "${LG_AGENT_CONFIG} exists but no agent identity could be resolved, so it can't be saved. Nothing was removed."
        fi
        log_info "No agent identity found on this machine; nothing to save."
        return 0
    fi
    host="$(hostname -s 2>/dev/null || uname -n)"
    host="${host%%.*}"
    created="$(date -u +%Y%m%dT%H%M%SZ)"
    dest="${1%/}/liongard-identity-${host}-${created}"
    if [ -e "${dest}" ]; then
        lg_exit "${EXIT_IDENTITY}" "${dest} already exists. Nothing was removed."
    fi
    if ! ( umask 077 && mkdir -m 0700 "${dest}" \
           && printf '%s\n' "${LG_ID_VALUE}" > "${dest}/machine-guid" \
           && {
                  echo "format_version=1"
                  echo "os=linux"
                  echo "hostname=${host}"
                  echo "created_utc=${created}"
                  echo "identity_source=${LG_ID_SOURCE}"
                  echo "identity_tier=${LG_ID_TIER}"
                  echo "agent_id=${LG_ID_AGENT_ID}"
                  echo "agent_name=$(lg_config_value AGENT_NAME)"
                  echo "agent_uid=$(lg_config_value AGENT_UID)"
                  echo "url=$(lg_config_value URL)"
                  echo "agent_version=$(lg_config_value AGENT_VERSION)"
                  echo "config_included=false"
                  echo "sha256_machine_guid=$(sha256sum -- "${dest}/machine-guid" | cut -d' ' -f1)"
              } > "${dest}/manifest.txt" \
           && chmod 0600 "${dest}/machine-guid" "${dest}/manifest.txt" ); then
        rm -rf -- "${dest}"
        lg_exit "${EXIT_IDENTITY}" "Could not write the agent identity backup to ${dest}. Nothing was removed."
    fi
    log_ok "Agent identity saved to ${dest} (identity ${LG_ID_VALUE}, source ${LG_ID_SOURCE}, AgentID ${LG_ID_AGENT_ID:-unknown}). It holds no key or secret."
}

# Clean install: an identity that lived only in the agent config is written to the identity file
# before the config is removed, so the reinstall keeps it.
lg_seed_identity() {
    local tmp
    if [ "${LG_ID_TIER}" != 2 ] || [ -e "${LG_GUID_FILE}" ] || ! [[ "${LG_ID_VALUE}" =~ ${LG_MACHINE_GUID_PATTERN} ]]; then return 0; fi
    if ! { mkdir -p -- "${LG_GUID_DIR}" && chmod 0700 "${LG_GUID_DIR}" && tmp="$(mktemp "${LG_GUID_DIR}/.machine-guid.XXXXXXXX")"; }; then
        lg_exit "${EXIT_IDENTITY}" "Could not write ${LG_GUID_FILE}. The agent was removed but not reinstalled; restore the identity with LGAgentIdentity-Linux.sh."
    fi
    if ! { printf '%s\n' "${LG_ID_VALUE}" > "${tmp}" && chmod 0600 "${tmp}" && mv -f -- "${tmp}" "${LG_GUID_FILE}"; }; then
        rm -f -- "${tmp}"
        lg_exit "${EXIT_IDENTITY}" "Could not write ${LG_GUID_FILE}. The agent was removed but not reinstalled; restore the identity with LGAgentIdentity-Linux.sh."
    fi
    log_info "Wrote the saved identity to ${LG_GUID_FILE}, so the reinstalled agent keeps it."
}

# Removes the agent and its leftovers. Keeps /etc/liongard-agent (identity) and the script logs.
lg_remove_local_agent() {
    local name dir path pkg
    log_step "Removing the Liongard Agent from this machine."
    if _lg_has systemctl; then
        for name in "${LG_UPDATER_SERVICE}.timer" "${LG_UPDATER_SERVICE}.service" "${LG_CORE_SERVICE}.service" ${LG_LEGACY_SERVICES} ${LG_LEGACY_UPDATER_TIMERS}; do
            systemctl stop "${name}" >/dev/null 2>&1
            systemctl disable "${name}" >/dev/null 2>&1
        done
    elif _lg_has service; then
        for name in "${LG_CORE_SERVICE}" ${LG_LEGACY_SERVICES}; do service "${name}" stop >/dev/null 2>&1; done
    fi
    for pkg in $(lg_deb_packages); do
        log_info "Removing package ${pkg}."
        if _lg_has apt-get; then
            DEBIAN_FRONTEND=noninteractive apt-get remove -y "${pkg}" < /dev/null >/dev/null 2>&1 || log_warn "apt-get remove ${pkg} failed."
        else
            dpkg --remove "${pkg}" < /dev/null >/dev/null 2>&1 || log_warn "dpkg --remove ${pkg} failed."
        fi
    done
    for pkg in $(lg_rpm_packages); do
        log_info "Removing package ${pkg}."
        if _lg_has dnf; then dnf remove -y "${pkg}" < /dev/null >/dev/null 2>&1 || log_warn "dnf remove ${pkg} failed."
        elif _lg_has yum; then yum remove -y "${pkg}" < /dev/null >/dev/null 2>&1 || log_warn "yum remove ${pkg} failed."
        elif _lg_has zypper; then zypper --non-interactive remove "${pkg}" < /dev/null >/dev/null 2>&1 || log_warn "zypper remove ${pkg} failed."
        else rpm -e "${pkg}" >/dev/null 2>&1 || log_warn "rpm -e ${pkg} failed."
        fi
    done
    for path in ${LG_UNINSTALL_SCRIPTS}; do
        if [ -f "${path}" ] && [ -x "${path}" ]; then
            log_info "Running ${path}."
            "${path}" < /dev/null >/dev/null 2>&1 || log_warn "${path} returned $?."
        fi
    done
    if _lg_has pkill; then
        pkill -TERM -f "^${LG_AGENT_DIR}/" >/dev/null 2>&1 && sleep 2
        pkill -KILL -f "^${LG_AGENT_DIR}/" >/dev/null 2>&1
        for name in ${LG_LEGACY_SERVICES}; do pkill -x "${name}" >/dev/null 2>&1; done
    fi
    for dir in ${LG_UNIT_DIRS}; do
        for name in "${LG_CORE_SERVICE}.service" "${LG_UPDATER_SERVICE}.service" "${LG_UPDATER_SERVICE}.timer"; do
            rm -f -- "${dir}/${name}" "${dir}/multi-user.target.wants/${name}" "${dir}/timers.target.wants/${name}"
        done
        for name in ${LG_LEGACY_SERVICES}; do rm -f -- "${dir}/${name}.service" "${dir}/multi-user.target.wants/${name}.service"; done
        for name in ${LG_LEGACY_UPDATER_TIMERS}; do rm -f -- "${dir}/${name}.timer" "${dir}/timers.target.wants/${name}.timer"; done
    done
    if _lg_has systemctl; then
        systemctl daemon-reload >/dev/null 2>&1
        for name in "${LG_CORE_SERVICE}" ${LG_LEGACY_SERVICES}; do systemctl reset-failed "${name}" >/dev/null 2>&1; done
    fi
    for path in ${LG_LEGACY_BINARIES}; do
        rm -f -- "${path}" 2>/dev/null || log_warn "Could not remove ${path}."
    done
    for dir in ${LG_AGENT_DIRS}; do
        if [ -e "${dir}" ]; then
            log_info "Removing ${dir}."
            rm -rf -- "${dir}" || log_warn "Could not remove ${dir}."
        fi
    done
}

# The names this machine can be registered under. No truncated variants; "localhost" is never used.
lg_local_hostnames() {
    local seen=" " n lc
    for n in "$(hostname 2>/dev/null)" "$(hostname -s 2>/dev/null)" "$(hostname -f 2>/dev/null)"; do
        n="${n%.}"
        lc="$(printf '%s' "${n}" | tr '[:upper:]' '[:lower:]')"
        if [ -z "${n}" ] || [ "${lc}" = localhost ] || [ "${lc}" = localhost.localdomain ] || [[ "${seen}" == *" ${lc} "* ]]; then continue; fi
        seen="${seen}${lc} "
        printf '%s\n' "${n}"
    done
}

# Usage: lg_download <url> <file>. Three attempts; a file smaller than 10 KB is rejected.
lg_download() {
    local attempt=1 size
    while [ "${attempt}" -le 3 ]; do
        rm -f -- "$2"
        if _lg_has curl; then
            curl -sSfL --connect-timeout 30 -o "$2" "$1" 2>/dev/null
        else
            wget -q -O "$2" "$1" 2>/dev/null
        fi
        size="$(wc -c < "$2" 2>/dev/null | tr -d ' ')"
        if [ -n "${size}" ] && [ "${size}" -ge "${LG_MIN_INSTALLER_BYTES}" ]; then
            log_ok "Downloaded ${1} (${size} bytes)."
            return 0
        fi
        log_warn "Download attempt ${attempt} of ${1} failed (${size:-0} bytes)."
        attempt=$((attempt + 1))
        if [ "${attempt}" -le 3 ]; then sleep 5; fi
    done
    return 1
}

# Usage: lg_installer_url <architecture setting> <installer url setting>. Prints the URL to use.
lg_installer_url() {
    local arch machine
    arch="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    case "${arch}" in
        auto|x64|arm64) ;;
        *) lg_exit "${EXIT_CONFIG}" "LINUX_ARCHITECTURE must be auto, x64 or arm64 (got '$1')." ;;
    esac
    if [ -n "$2" ]; then printf '%s' "$2"; return 0; fi
    if [ "${arch}" = auto ]; then
        machine="$(uname -m 2>/dev/null)"
        case "${machine}" in
            x86_64) arch=x64 ;;
            aarch64|arm64) arch=arm64 ;;
            *) lg_exit "${EXIT_PREREQUISITE}" "Unsupported CPU architecture '${machine}'. The installer exists for x86_64 and aarch64 only." ;;
        esac
    fi
    printf 'https://agents.static.liongard.com/LiongardAgent-lts-%s.xz.run' "${arch}"
}

# Prints deb, rpm or sh from the installer file name.
lg_installer_type() {
    local name="${1%%\?*}"
    case "$(printf '%s' "${name##*.}" | tr '[:upper:]' '[:lower:]')" in
        deb) echo deb ;;
        rpm) echo rpm ;;
        run|sh|bin) echo sh ;;
    esac
}

# Runs the downloaded installer with the settings; returns its exit code.
lg_run_installer() {
    local name rc=0 out flag i
    local -a args=()
    name="${AGENT_NAME:-$(hostname 2>/dev/null)}"
    out="$(mktemp "${LG_WORK_DIR}/installer-output.XXXXXXXX")" || return 1
    log_step "Running the installer (${LG_INSTALLER_TYPE})."
    if [ "${LG_INSTALLER_TYPE}" = sh ]; then
        # The makeself installer reads flags after "--": -u -k -s -n -e -d -p -g and --reset-identity.
        args=(-- -u "${LG_INSTALL_HOST}" -k "${AGENT_TOKEN_KEY}" -s "${AGENT_TOKEN_SECRET}" -n "${name}")
        if [ -n "${LG_INSTALL_ENVIRONMENT}" ]; then args+=(-e "${LG_INSTALL_ENVIRONMENT}"); fi
        if [ -n "${AGENT_DESCRIPTION}" ]; then args+=(-d "${AGENT_DESCRIPTION}"); fi
        if [ -n "${PROXY_URL}" ]; then args+=(-p "${PROXY_URL}"); fi
        if [ -n "${DEVICE_GUID}" ]; then args+=(-g "${DEVICE_GUID}"); fi
        if [ "${RESET_IDENTITY}" = true ]; then args+=(--reset-identity); fi
        flag="Installer flags:"
        for (( i = 1; i < ${#args[@]}; i++ )); do flag="${flag} ${args[i]}"; done
        log_info "${flag}"
        chmod 0700 "${LG_INSTALLER_FILE}"
        "${LG_INSTALLER_FILE}" "${args[@]}" < /dev/null > "${out}" 2>&1 || rc=$?
    else
        log_info "Installer settings: LIONGARDURL=${LG_INSTALL_HOST} LIONGARDAGENTNAME=${name} LIONGARDENVIRONMENT=${LG_INSTALL_ENVIRONMENT} LIONGARDDESCRIPTION=${AGENT_DESCRIPTION}"
        if [ "${LG_INSTALLER_TYPE}" = deb ]; then
            LIONGARDURL="${LG_INSTALL_HOST}" LIONGARDACCESSKEY="${AGENT_TOKEN_KEY}" LIONGARDACCESSSECRET="${AGENT_TOKEN_SECRET}" \
                LIONGARDAGENTNAME="${name}" LIONGARDENVIRONMENT="${LG_INSTALL_ENVIRONMENT}" LIONGARDDESCRIPTION="${AGENT_DESCRIPTION}" \
                DEBIAN_FRONTEND=noninteractive dpkg -i "${LG_INSTALLER_FILE}" < /dev/null > "${out}" 2>&1 || rc=$?
        elif _lg_has dnf || _lg_has yum || _lg_has zypper || _lg_has rpm; then
            LIONGARDURL="${LG_INSTALL_HOST}" LIONGARDACCESSKEY="${AGENT_TOKEN_KEY}" LIONGARDACCESSSECRET="${AGENT_TOKEN_SECRET}" \
                LIONGARDAGENTNAME="${name}" LIONGARDENVIRONMENT="${LG_INSTALL_ENVIRONMENT}" LIONGARDDESCRIPTION="${AGENT_DESCRIPTION}" \
                rpm -Uvh "${LG_INSTALLER_FILE}" < /dev/null > "${out}" 2>&1 || rc=$?
        else
            log_error "No rpm command found for an .rpm installer."
            rc=127
        fi
    fi
    while IFS= read -r i; do log_info "installer: ${i}"; done < "${out}"
    rm -f -- "${out}"
    return "${rc}"
}

# True when the agent service runs (waits up to 60 seconds) and the updater timer is registered.
lg_validate_install() {
    local i=0 timer
    while ! lg_service_running && [ "${i}" -lt 12 ]; do sleep 5; i=$((i + 1)); done
    timer="$(lg_unit_file "${LG_UPDATER_SERVICE}.timer")" || timer=""
    log_info "Validation: ${LG_CORE_SERVICE} running: $(lg_service_running && echo true || echo false); updater timer: ${timer:-missing}"
    lg_service_running && [ -n "${timer}" ]
}

lg_cleanup_work_dir() {
    if [ -n "${LG_WORK_DIR}" ] && [ -d "${LG_WORK_DIR}" ]; then rm -rf -- "${LG_WORK_DIR}"; fi
}

# Usage: lg_install_main <simple|advanced|clean>
lg_install_main() {
    local mode="$1" installed="" available="" leftovers line
    lg_require_root
    lg_start_log "${LOG_DIRECTORY:-/var/log/liongard-agent}" LGAgentScript
    lg_add_secret "${AGENT_TOKEN_KEY}"
    lg_add_secret "${AGENT_TOKEN_SECRET}"
    lg_add_secret "${API_TOKEN_KEY:-}"
    lg_add_secret "${API_TOKEN_SECRET:-}"
    log_step "Liongard Agent ${mode} install on $(hostname 2>/dev/null)."

    lg_require INSTANCE_PREFIX "${INSTANCE_PREFIX}"
    lg_require AGENT_TOKEN_KEY "${AGENT_TOKEN_KEY}"
    lg_require AGENT_TOKEN_SECRET "${AGENT_TOKEN_SECRET}"
    lg_require_bool INCLUDE_ENVIRONMENT_VALUE "${INCLUDE_ENVIRONMENT_VALUE}"
    lg_require_bool RESET_IDENTITY "${RESET_IDENTITY}"
    if [ "${INCLUDE_ENVIRONMENT_VALUE}" = true ]; then lg_require ENVIRONMENT "${ENVIRONMENT}"; fi
    if [ "${mode}" = advanced ]; then
        lg_require API_TOKEN_KEY "${API_TOKEN_KEY}"
        lg_require API_TOKEN_SECRET "${API_TOKEN_SECRET}"
    fi
    LG_INSTALL_HOST="$(lg_instance_host "${INSTANCE_PREFIX}")" || lg_exit "${EXIT_CONFIG}" "INSTANCE_PREFIX '${INSTANCE_PREFIX}' is not a Liongard instance such as us1 or us1.app.liongard.com."
    if [ -n "${DEVICE_GUID}" ] && ! [[ "${DEVICE_GUID}" =~ ${LG_MACHINE_GUID_PATTERN} ]]; then
        lg_exit "${EXIT_CONFIG}" "DEVICE_GUID [${DEVICE_GUID}] is invalid. Allowed: letters, digits, '.', '_' and '-' (max 128, starts with a letter or digit)."
    fi
    INSTALLER_URL="$(lg_installer_url "${LINUX_ARCHITECTURE}" "${INSTALLER_URL}")" || exit $?
    LG_INSTALLER_TYPE="$(lg_installer_type "${INSTALLER_FILE_NAME:-${INSTALLER_URL##*/}}")"
    if [ -z "${LG_INSTALLER_TYPE}" ]; then lg_exit "${EXIT_CONFIG}" "Cannot tell the installer type from [${INSTALLER_URL}]. Use a .run, .sh, .deb or .rpm installer."; fi
    if [ "${LG_INSTALLER_TYPE}" != sh ] && { [ -n "${PROXY_URL}" ] || [ -n "${DEVICE_GUID}" ] || [ "${RESET_IDENTITY}" = true ]; }; then
        lg_exit "${EXIT_CONFIG}" "PROXY_URL, DEVICE_GUID and RESET_IDENTITY reach only the .run installer, not a .${LG_INSTALLER_TYPE} package."
    fi
    if ! _lg_has curl && ! _lg_has wget; then lg_exit "${EXIT_PREREQUISITE}" "curl or wget is required."; fi
    if [ "${mode}" = advanced ] && { ! _lg_has curl || ! _lg_has jq; }; then lg_exit "${EXIT_PREREQUISITE}" "curl and jq are required for the environment check."; fi
    log_info "Instance ${LG_INSTALL_HOST}; installer ${INSTALLER_URL}; agent name ${AGENT_NAME:-(hostname)}; environment ${ENVIRONMENT} (sent: ${INCLUDE_ENVIRONMENT_VALUE}); description ${AGENT_DESCRIPTION:-(none)}; proxy ${PROXY_URL:-(none)}; device GUID ${DEVICE_GUID:-(none)}; reset identity ${RESET_IDENTITY}"

    if [ "${mode}" = clean ]; then lg_prepare_existing_agent; fi
    lg_install_state "${mode}"
    if [ "${LG_STATE}" = Stale ] && [ "${mode}" != clean ]; then
        lg_exit "${EXIT_STALE}" "The installed agent is broken or not running (Stale). Nothing was changed. Run LGAgentCleanInstall-Linux-Simple.sh to repair it."
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

    LG_WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/liongard-agent.XXXXXXXX")" || lg_exit "${EXIT_PREREQUISITE}" "Could not create a private download folder."
    trap lg_cleanup_work_dir EXIT
    LG_INSTALLER_FILE="${LG_WORK_DIR}/${INSTALLER_FILE_NAME:-installer.${INSTALLER_URL##*.}}"
    LG_INSTALLER_FILE="${LG_INSTALLER_FILE%%\?*}"
    lg_download "${INSTALLER_URL}" "${LG_INSTALLER_FILE}" || lg_exit "${EXIT_DOWNLOAD}" "The installer download failed. Nothing was changed."

    if [ "${LG_STATE}" = Healthy ]; then
        installed="$(lg_installed_version)"
        available="$(lg_installer_version "${LG_INSTALLER_FILE}")"
        log_info "Installed agent version: ${installed:-unreadable}; installer version: ${available:-unreadable}."
        if [ -z "${installed}" ] || [ -z "${available}" ]; then
            lg_exit "${EXIT_DOWNLOAD}" "The versions can't be compared, so the agent was not upgraded. Nothing was changed."
        fi
        if ! lg_version_newer "${available}" "${installed}"; then
            lg_exit "${EXIT_OK}" "Liongard Agent ${installed} is installed and running, and the installer (${available}) is not newer. Nothing to do."
        fi
        log_info "Upgrading the agent from ${installed} to ${available}. It keeps its registration."
    elif [ "${mode}" = clean ]; then
        lg_collect_identity
        lg_save_identity_backup "${LOG_DIRECTORY:-/var/log/liongard-agent}"
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

    lg_run_installer || lg_exit "${EXIT_INSTALLER}" "The installer failed (exit $?)."
    lg_validate_install || lg_exit "${EXIT_VALIDATION}" "The installer finished, but the agent service is not running or the updater timer is missing."
    lg_exit "${EXIT_OK}" "The Liongard Agent is installed and running."
}

# Usage: lg_uninstall_main <simple|advanced>
lg_uninstall_main() {
    local mode="$1" leftovers line rc
    local -a names=()
    lg_require_root
    lg_start_log "${LOG_DIRECTORY:-/var/log/liongard-agent}" LGAgentUninstall
    if [ "${mode}" = advanced ]; then lg_check_platform_settings; fi
    lg_collect_identity
    lg_save_identity_backup "${LOG_DIRECTORY:-/var/log/liongard-agent}"
    leftovers="$(lg_agent_leftovers)"
    if [ -z "${leftovers}" ]; then
        log_info "No Liongard Agent found on this machine. Nothing to remove locally."
    else
        while IFS= read -r line; do log_info "  Found: ${line}"; done <<< "${leftovers}"
        lg_remove_local_agent
        leftovers="$(lg_agent_leftovers)"
        if [ -n "${leftovers}" ]; then
            while IFS= read -r line; do log_error "  Still present: ${line}"; done <<< "${leftovers}"
            lg_exit "${EXIT_REMOVAL}" "The Liongard Agent is still detected after the removal. The platform record was not touched."
        fi
        log_ok "The Liongard Agent is removed from this machine."
    fi
    if [ -f "${LG_GUID_FILE}" ]; then log_info "Agent identity ${LG_GUID_FILE} kept, so a reinstall re-attaches to the same record."; fi
    if [ "${mode}" = advanced ] && [ "${REMOVE_AGENT_FROM_PLATFORM}" = true ]; then
        while IFS= read -r line; do if [ -n "${line}" ]; then names+=("${line}"); fi; done <<< "$(lg_local_hostnames)"
        rc=0
        lg_remove_platform_record "${ENVIRONMENT}" ${names[@]+"${names[@]}"} || rc=$?
        case "${rc}" in
            0) ;;
            2) log_warn "No platform record qualified; nothing was deleted. It may already be gone." ;;
            *) lg_exit "${EXIT_PLATFORM}" "The platform record was not removed (see above). The agent was removed from this machine." ;;
        esac
    fi
    lg_exit "${EXIT_OK}" "Uninstall finished."
}

# END SHARED BLOCK: Liongard Linux agent functions

# BEGIN SHARED BLOCK: Liongard platform record removal
# Identical in the Linux and macOS Uninstall-Advanced scripts. Needs jq. Nothing is deleted unless exactly one record qualifies.

lg_json_list() {
    printf '%s\n' "$1" | sed '/^$/d' | jq -R 'ascii_downcase' | jq -sc '.'
}

lg_json_keys() {
    local v out=""
    while IFS= read -r v; do
        if [ -n "${v}" ]; then out="${out}$(lg_id_key "${v}")"$'\n'; fi
    done <<< "$(lg_values "$1")"
    lg_json_list "${out}"
}

lg_api_agents() {
    local response
    response="$(_api_get "$1" 2>/dev/null)" || return 1
    printf '%s' "${response}" | jq -c '
        if type == "array" then .
        elif type == "object" and (.data | type) == "array" then .data
        else error("unexpected response") end' 2>/dev/null
}

lg_environment_ids() {
    local response
    response="$(_api_get "/environments" 2>/dev/null)" || return 1
    printf '%s' "${response}" | jq -r --arg n "$1" '
        (if type == "array" then . elif (.data | type) == "array" then .data else error("unexpected response") end)
        | .[] | select(((.Name // .name // "") | ascii_downcase) == ($n | ascii_downcase))
        | (.ID // .id // empty) | tostring' 2>/dev/null
}

LG_ROWS_JQ='
    def key: tostring | gsub("\\s"; "") | ltrimstr("{") | rtrimstr("}") | ascii_downcase;
    def junk: . == "" or . == "local" or . == "uninitialized" or (gsub("[0{}-]"; "") == "") or (test("[0-9a-f]") | not);
    [ .[] | select(type == "object")
      | (.Environment | type) as $et
      | { id:       ((.ID // .id // "") | tostring),
          guid:     ((.MachineGuid // "") | tostring),
          names:    ([.Hostname, .Name, (.Data.FQDN? // null)] | map(select(type == "string" and length > 0))),
          env_name: (((if $et == "object" then .Environment.Name elif $et == "string" then .Environment else null end) // .EnvironmentName // "") | tostring),
          env_id:   ((((if $et == "object" then .Environment.ID else null end) // .EnvironmentID // "") | tostring) | if . == "0" then "" else . end) }
      | select(.id != "")
      | (.guid | key) as $g
      | .guid_set = ($g | junk | not)
      | .guid_kind = (if (.guid_set | not) then "" elif any($agent[]; . == $g) then "agent" elif any($os[]; . == $g) then "os" else "" end)
      | .name_hit = (first(.names[] | select(ascii_downcase as $n | any($names[]; . == $n))) // "")
      | .env_ok = (if $want == "" then (.env_name == "" and .env_id == "")
                   elif .env_name != "" then ((.env_name | ascii_downcase) == ($want | ascii_downcase))
                   elif .env_id != "" then (.env_id as $i | any($envids[]; . == $i))
                   else false end)
      | .env_label = (if .env_name != "" then .env_name elif .env_id != "" then "ID \(.env_id)" else "(none)" end) ]
    | unique_by(.id)'

# Usage: lg_rows <agents json> <environment> <names json> <agent keys json> <os keys json>
lg_rows() {
    local rows envids="[]" ids
    rows="$(jq -c --arg want "$2" --argjson names "$3" --argjson agent "$4" --argjson os "$5" --argjson envids "${envids}" "${LG_ROWS_JQ}" <<< "$1" 2>/dev/null)" || return 1
    # Environment IDs are fetched only when a record carries an ID without a name.
    if [[ -n "$2" ]] && jq -e 'any(.[]; .env_name == "" and .env_id != "")' <<< "${rows}" >/dev/null 2>&1; then
        ids="$(lg_environment_ids "$2")" || { log_error "Could not look up the ID of environment [$2]."; return 1; }
        envids="$(lg_json_list "${ids}")"
        rows="$(jq -c --arg want "$2" --argjson names "$3" --argjson agent "$4" --argjson os "$5" --argjson envids "${envids}" "${LG_ROWS_JQ}" <<< "$1" 2>/dev/null)" || return 1
    fi
    printf '%s' "${rows}"
}

# Adds .ok and .why to each row for a step: agent_id, machine_guid or hostname.
LG_VERDICT_JQ='
    map(. + (
        if $step == "agent_id" then
            (if .guid_set and .guid_kind == "" then {ok: false, why: "conflict: its MachineGuid matches no local identifier"}
             elif .name_hit == "" and (.env_ok | not) then {ok: false, why: "neither a local name nor the environment matches"}
             elif .guid_kind == "os" and .name_hit == "" then {ok: false, why: "its MachineGuid matches only an OS identifier, which clones share, and no local name matches"}
             else {ok: true, why: "match (AgentID\(if .guid_kind != "" then ", MachineGuid (\(.guid_kind))" else "" end)\(if .name_hit != "" then ", name [\(.name_hit)]" else "" end)\(if .env_ok then ", environment" else "" end))"} end)
        elif $step == "machine_guid" then
            ([ (if .guid_kind == "" then "MachineGuid matches no local identifier" else empty end),
               (if .env_ok then empty else "environment differs" end),
               (if .guid_kind == "os" and .name_hit == "" then "MachineGuid matches only an OS identifier and no local name matches" else empty end) ]) as $r
            | if ($r | length) == 0 then {ok: true, why: "match (MachineGuid (\(.guid_kind)) and environment)"} else {ok: false, why: ($r | join("; "))} end
        else
            ([ (if .name_hit == "" then "no Hostname, Name or FQDN equals a local name" else empty end),
               (if .env_ok then empty else "environment differs" end),
               (if .guid_set and .guid_kind == "" then "its MachineGuid is set and matches no local identifier" else empty end) ]) as $r
            | if ($r | length) == 0 then {ok: true, why: "match (hostname [\(.name_hit)] and environment)"} else {ok: false, why: ($r | join("; "))} end
        end))'

# Usage: lg_judge <step> <rows json>. Logs every candidate and prints the rows that qualify.
lg_judge() {
    local judged line
    judged="$(jq -c --arg step "$1" "${LG_VERDICT_JQ}" <<< "$2")" || return 1
    log_info "Candidates for step [$1]: $(jq 'length' <<< "${judged}")"
    while IFS= read -r line; do
        if [ -n "${line}" ]; then log_info "  ${line}"; fi
    done <<< "$(jq -r '.[] | "Agent ID \(.id): MachineGuid [\(.guid | gsub("\n"; "\\n"))], names [\(.names | join(", "))], environment [\(.env_label)] -> \(.why)"' <<< "${judged}")"
    jq -c '[.[] | select(.ok)]' <<< "${judged}"
}

# Confirms with a GET, because the API DELETE can hang after the record is already gone.
lg_delete_agent() {
    local id="$1" status left
    status="$(_api_delete "/agents/${id}")" || true
    log_info "DELETE /agents/${id} returned HTTP ${status:-000}."
    if ! left="$(lg_api_agents "/agents/${id}")"; then
        log_error "Could not confirm the deletion of agent ID ${id}: the lookup failed."
        return 1
    fi
    if [[ "$(jq 'length' <<< "${left}")" != "0" ]]; then
        log_error "Agent ID ${id} still exists on the platform after the delete call (HTTP ${status:-000})."
        return 1
    fi
    log_ok "Platform record for agent ID ${id} deleted."
}

# Returns 0 deleted, 1 failure (more than one candidate or a failed delete), 2 no candidate.
lg_delete_single_match() {
    local signal="$1" matched="$2" count id
    count="$(jq 'length' <<< "${matched}")"
    if [[ "${count}" -eq 0 ]]; then
        return 2
    fi
    if [[ "${count}" -gt 1 ]]; then
        log_error "Not deleting: ${count} records match by ${signal} ($(jq -r '[.[].id] | join(", ")' <<< "${matched}")). Exactly one is required."
        return 1
    fi
    id="$(jq -r '.[0].id' <<< "${matched}")"
    log_info "Deleting agent ID ${id} (matched by ${signal})."
    lg_delete_agent "${id}"
}

# Prints the value and, when it differs, its lowercase form: the API "=" filter is case-sensitive.
lg_query_forms() {
    local lc
    lc="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    printf '%s\n' "$1"
    if [[ "${lc}" != "$1" ]]; then printf '%s\n' "${lc}"; fi
}

# Usage: lg_query_agents <variable> <condition>. Appends the matching records to the named JSON array.
lg_query_agents() {
    local batch merged
    batch="$(lg_api_agents "/agents?conditions=$(url_encode "$2")")" || { log_error "Lookup [$2] failed."; return 1; }
    eval "merged=\"\${$1}\""
    merged="$(jq -c --argjson b "${batch}" '. + $b' <<< "${merged}")" || return 1
    printf -v "$1" '%s' "${merged}"
}

# Usage: lg_remove_platform_record <environment> <local name>...
# Returns 0 deleted, 1 failure (nothing more is tried), 2 no record qualified.
lg_remove_platform_record() {
    local wanted="$1"; shift
    local names_json agent_json os_json agents rows ok value form escaped field rc q="'"

    names_json="$(lg_json_list "$(printf '%s\n' "$@")")"
    agent_json="$(lg_json_keys "${LG_ID_AGENT}")"
    os_json="$(lg_json_keys "${LG_ID_OS}")"
    log_step "Removing the platform record: AgentID [${LG_ID_AGENT_ID:-none}], environment [${wanted:-none}], local names [$*]."
    while IFS= read -r value; do
        if [[ -n "${value}" ]]; then log_info "  Agent identifier ${value}"; fi
    done <<< "${LG_ID_AGENT}"
    while IFS= read -r value; do
        if [[ -n "${value}" ]]; then log_info "  OS identifier ${value} (also needs a local name match)"; fi
    done <<< "${LG_ID_OS}"

    if [[ -n "${LG_ID_AGENT_ID}" ]]; then
        if [[ ! "${LG_ID_AGENT_ID}" =~ ^[0-9]+$ ]]; then
            log_error "The local AgentID [${LG_ID_AGENT_ID}] is not a number."
            return 1
        fi
        agents="$(lg_api_agents "/agents/${LG_ID_AGENT_ID}")" || { log_error "Lookup by AgentID ${LG_ID_AGENT_ID} failed."; return 1; }
        rows="$(lg_rows "${agents}" "${wanted}" "${names_json}" "${agent_json}" "${os_json}")" || { log_error "Could not read the AgentID lookup result."; return 1; }
        if [[ "$(jq 'length' <<< "${rows}")" -gt 0 ]]; then
            ok="$(lg_judge agent_id "${rows}")" || return 1
            if [[ "$(jq 'length' <<< "${ok}")" -eq 0 ]]; then
                log_error "Not deleting agent ID ${LG_ID_AGENT_ID}: the record does not belong to this machine (see the candidate line)."
                return 1
            fi
            rc=0
            lg_delete_single_match "AgentID" "${ok}" || rc=$?
            return "${rc}"
        fi
        log_warn "No platform record has AgentID ${LG_ID_AGENT_ID}. Trying the MachineGuid."
    else
        log_info "No local AgentID found. Trying the MachineGuid."
    fi

    if [[ -n "$(lg_values "${LG_ID_AGENT}${LG_ID_OS}")" ]]; then
        agents="[]"
        while IFS= read -r value; do
            if [[ -z "${value}" ]]; then continue; fi
            while IFS= read -r form; do
                escaped="${form//$q/$q$q}"
                lg_query_agents agents "MachineGuid = '${escaped}'" || return 1
                lg_query_agents agents "MachineGuid like '${escaped}%'" || return 1
            done <<< "$(lg_query_forms "${value}")"
        done <<< "$(lg_values "${LG_ID_AGENT}${LG_ID_OS}")"
        rows="$(lg_rows "${agents}" "${wanted}" "${names_json}" "${agent_json}" "${os_json}")" || { log_error "Could not read the MachineGuid lookup result."; return 1; }
        ok="$(lg_judge machine_guid "${rows}")" || return 1
        rc=0
        lg_delete_single_match "MachineGuid and environment" "${ok}" || rc=$?
        if [[ "${rc}" -ne 2 ]]; then return "${rc}"; fi
        log_warn "No record matches a local MachineGuid in environment [${wanted:-none}]. Trying the hostname."
    else
        log_info "No usable local MachineGuid found. Trying the hostname."
    fi

    if [[ "$#" -eq 0 ]]; then
        log_warn "No local hostname could be determined."
        return 2
    fi
    agents="[]"
    for value in "$@"; do
        while IFS= read -r form; do
            escaped="${form//$q/$q$q}"
            for field in Hostname Name; do
                lg_query_agents agents "${field} = '${escaped}'" || return 1
            done
        done <<< "$(lg_query_forms "${value}")"
    done
    rows="$(lg_rows "${agents}" "${wanted}" "${names_json}" "${agent_json}" "${os_json}")" || { log_error "Could not read the hostname lookup result."; return 1; }
    ok="$(lg_judge hostname "${rows}")" || return 1
    lg_delete_single_match "hostname and environment" "${ok}"
}

# END SHARED BLOCK: Liongard platform record removal

lg_check_platform_settings() {
    local host
    lg_require_bool REMOVE_AGENT_FROM_PLATFORM "${REMOVE_AGENT_FROM_PLATFORM}"
    if [ "${REMOVE_AGENT_FROM_PLATFORM}" != true ]; then
        log_info "REMOVE_AGENT_FROM_PLATFORM=false: the platform record is kept."
        return 0
    fi
    lg_add_secret "${API_TOKEN_KEY}"
    lg_add_secret "${API_TOKEN_SECRET}"
    lg_require INSTANCE_PREFIX "${INSTANCE_PREFIX}"
    lg_require API_TOKEN_KEY "${API_TOKEN_KEY}"
    lg_require API_TOKEN_SECRET "${API_TOKEN_SECRET}"
    case "${ENVIRONMENT}" in REPLACE_WITH_*) lg_exit "${EXIT_CONFIG}" "ENVIRONMENT is still a placeholder; set it, or leave it blank for an agent without an environment." ;; esac
    host="$(lg_instance_host "${INSTANCE_PREFIX}")" || lg_exit "${EXIT_CONFIG}" "INSTANCE_PREFIX '${INSTANCE_PREFIX}' is not a Liongard instance such as us1 or us1.app.liongard.com."
    if ! _lg_has curl || ! _lg_has jq; then lg_exit "${EXIT_PREREQUISITE}" "curl and jq are required to remove the platform record. Nothing was removed."; fi
    lg_api_setup "${host}" "${API_TOKEN_KEY}" "${API_TOKEN_SECRET}"
}

lg_uninstall_main advanced
