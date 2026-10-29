#!/usr/bin/env bash
#
# SYNOPSIS
#   Installs the Liongard Agent on Linux (.deb, .rpm, .run or .sh installer).
#
# DESCRIPTION
#   Installs the Liongard Agent and registers it with your Liongard instance.
#   Set your values in sections A and B of the configuration block below. Exit codes, logs
#   and troubleshooting are in the README under LINK.
#   - Checks prerequisites and picks the x64 or arm64 installer.
#   - Checks the existing agent, then the API token (a failure stops the run before any
#     change, or is a WARN for a healthy agent). A healthy agent is never removed: it's
#     upgraded in place only when the installer is newer, otherwise the script exits 0
#     without changes. A broken or incomplete install is removed before installing, after
#     the environment and collision checks. The platform record is kept unless
#     REMOVE_AGENT_FROM_PLATFORM=true, and is then deleted only when exactly one agent has
#     the same environment and hostname.
#   - Matches the environment name through the Liongard API by default
#     (ENABLE_ENVIRONMENT_MATCHING=true) and checks for machine-ID collisions. An
#     environment that does not exist is left out with a WARN (or created when
#     CREATE_ENVIRONMENT_IF_MISSING=true); an ambiguous name stops the install.
#   - Downloads the installer to a private temporary folder and installs it.
#   - Confirms the agent service is running.
#
# NOTES
#   Requires:     root, Bash 4+, curl or wget, and jq for environment matching or platform removal.
#                 Liongard API token and agent install token (key and secret for each).
#   Author:       Liongard Partner Support
#   Last updated: 2026-10-29
#
# LINK
#   https://github.com/liongard/agent-scripts/blob/main/linux/README.md

# Abort on unset variables and propagate pipeline failures.
# Individual functions use explicit || handling for expected non-zero returns.
set -euo pipefail

# ############################################################
# #                                                          #
# #   PARTNER CONFIGURATION                                  #
# #                                                          #
# #   Update sections A and B below before deploying.        #
# #   Section C (Advanced) should normally be left as-is.    #
# #                                                          #
# ############################################################

# ------------------------------------------------------------
# A. REQUIRED CONFIGURATION — you MUST update these
# ------------------------------------------------------------

# Liongard instance identifier. Accepts any of:
#   us1                          → prefix: us1
#   us1.app.liongard.com         → prefix: us1
#   https://us1.app.liongard.com → prefix: us1
INSTANCE_PREFIX="REPLACE_WITH_INSTANCE_PREFIX"         # e.g. us1, us2, eu1

# API token (key + secret): used for environment lookup and collision detection.
API_TOKEN_KEY="REPLACE_WITH_API_TOKEN_KEY"
API_TOKEN_SECRET="REPLACE_WITH_API_TOKEN_SECRET"

# Agent token (key + secret): used to register/install the agent.
AGENT_TOKEN_KEY="REPLACE_WITH_AGENT_TOKEN_KEY"
AGENT_TOKEN_SECRET="REPLACE_WITH_AGENT_TOKEN_SECRET"

# Environment name to register the agent under.
# Required only when INCLUDE_ENVIRONMENT_VALUE=true.
# May be a static environment name or an RMM variable injection.
ENVIRONMENT="REPLACE_WITH_ENVIRONMENT_NAME"

# ------------------------------------------------------------
# B. OPTIONAL PARTNER CONFIGURATION — commonly changed
# ------------------------------------------------------------

# Pass the environment name to the installer during registration.
# Set to false to install without assigning an environment (ENVIRONMENT above
# is then not required).
INCLUDE_ENVIRONMENT_VALUE=true

# Look up the environment in Liongard and match/normalize the name before
# installing (requires jq). Set to false to use the ENVIRONMENT value verbatim.
# If no environment matches, the agent is installed without one and a WARN is
# logged; assign it in Liongard afterwards.
ENABLE_ENVIRONMENT_MATCHING=true

# Off by default. When true, only an exact (case-insensitive) name match counts,
# and an environment that does not exist is created through the API with the
# name as written. Needs ENABLE_ENVIRONMENT_MATCHING=true and an API token that
# is allowed to create environments. If creating fails, the agent is installed
# without an environment.
CREATE_ENVIRONMENT_IF_MISSING=false

# After the script removes a stale (broken or incomplete) local agent, also
# delete the matching agent record from the Liongard platform via the API.
# Never applies to a healthy agent, which is not removed.
REMOVE_AGENT_FROM_PLATFORM=false

# Optional free-text description for the agent. Passed only when non-empty.
AGENT_DESCRIPTION=""

# Directory for the log transcript. Created root-only (0700) when missing.
LOG_DIRECTORY="/var/log/liongard-agent"

# DEPRECATED: no longer used and will be removed in a later release. The
# installer now downloads to a private temporary directory that is removed on
# exit, and the log transcript goes to LOG_DIRECTORY. A WARN is logged if set.
DOWNLOAD_DIRECTORY=""

# DEPRECATED: no longer used and will be removed in a later release. The
# script now checks the existing install first: a healthy agent is left as it
# is or upgraded in place, and only a stale install is removed before
# installing. A WARN is logged if set.
ENABLE_PRE_UNINSTALL=""

# CPU architecture of the installer to download. "auto" picks it from
# uname -m (x86_64 → x64, aarch64 → arm64) and stops with an error on any
# other machine type. "x64" or "arm64" forces one.
LINUX_ARCHITECTURE="auto"

# Installer download URL. Leave empty to use the LTS installer for
# LINUX_ARCHITECTURE. When set, it is used as-is and LINUX_ARCHITECTURE is
# ignored. Package type is inferred from the file extension
# (.deb / .rpm / .sh / .run). NOTE: the MachineGuid collision override (passed
# to the installer via -g) requires an agent installer v5.4.0 or newer; older
# builds silently ignore it.
INSTALLER_URL=""

# Saved installer filename. Leave empty to infer it from the URL.
INSTALLER_FILE_NAME=""

# ------------------------------------------------------------
# C. ADVANCED OPTIONS — normally leave unchanged
# Advanced options below should normally remain unchanged unless directed
# by Liongard Support.
# ------------------------------------------------------------

# DEPRECATED: no longer used and will be removed in a later release. Remote
# deletion now needs exactly one agent with the same environment and hostname
# (see the README). A WARN is logged if this is changed from 50.
MINIMUM_REMOTE_DELETION_SCORE=50

# Candidate service names to check for, in priority order.
SERVICE_NAMES=("roaragent" "liongard-agent" "liongardagent" "LiongardAgent")

# Installer property name for the device-identifier override.
DEVICE_ID_OVERRIDE_ARG_NAME="DEVICEID"

# Behavior when the Liongard API call for collision detection fails:
#   conservative → abort (safest default; recommended for production)
#   permissive   → continue without a DEVICEID override
API_FAILURE_BEHAVIOR="conservative"

# Minimum downloaded file size (bytes) to consider the installer valid.
MINIMUM_INSTALLER_BYTES=10240   # 10 KB; raise to 1048576 for large packages

# Number of download attempts before giving up.
MAX_DOWNLOAD_ATTEMPTS=3

# ============================================================
# INSTALLER PARAMETER MAPPING — internal, not partner configuration
# Centralised so they can be adjusted if the Linux installer uses different
# argument names than the Windows MSI properties. Partners do not edit these.
# ============================================================
readonly PARAM_URL="LIONGARDURL"
readonly PARAM_ACCESS_KEY="LIONGARDACCESSKEY"
readonly PARAM_ACCESS_SECRET="LIONGARDACCESSSECRET"
readonly PARAM_AGENT_NAME="LIONGARDAGENTNAME"
readonly PARAM_ENVIRONMENT="LIONGARDENVIRONMENT"
readonly PARAM_DESCRIPTION="LIONGARDDESCRIPTION"

# Paths and unit names used by the current .run installer (read from the
# installer bundle, agent v5.5.0). Used to tell a healthy install from a stale one.
readonly AGENT_INSTALL_DIR="/opt/liongard"
readonly AGENT_BINARY_PATH="${AGENT_INSTALL_DIR}/LiongardAgent"
readonly AGENT_CONFIG_PATH="${AGENT_INSTALL_DIR}/.config"
readonly AGENT_CORE_SERVICE="liongard-agent"

# ============================================================
# INTERNAL STATE — do not edit below this line
# ============================================================
_SCRIPT_LOG_FILE=""
_INSTANCE_HOST=""
_INSTANCE_BASE_URL=""
_AUTH_HEADER_VALUE=""   # base64(key:secret) — never printed raw
_PKG_TYPE=""            # deb | rpm | sh
_PKG_MANAGER=""         # apt | yum | dnf | zypper | rpm | dpkg
_DETECTED_SVC=""        # which service name was actually found
_DEVICE_GUID_OVERRIDE=""
_RESOLVED_ENVIRONMENT=""
_ENVIRONMENT_WARNING="" # set when the environment is left out; repeated at the end
_HTTP_CLIENT=""         # curl | wget
_INSTALLER_PATH=""      # set by download_installer; avoids stdout-capture pollution
_WORK_DIR=""            # private mktemp -d directory; removed on exit
_WGET_CONFIG_FILE=""    # 0600 wgetrc holding the auth header; removed on exit
_INSTALL_STATE=""       # Healthy | Stale | NotInstalled (set by get_install_state)

# ============================================================
# LOGGING
# ============================================================

_log() {
    local level="$1"; shift
    local msg="$*"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    local line="[${ts}][${level}] ${msg}"

    # All log output goes to STDERR. stdout is reserved exclusively for function
    # return values captured via $(...). If logs went to stdout, capturing a
    # function that also logs (e.g. get_local_machine_id, get_agents_filtered)
    # would fold the log lines into the returned value and corrupt it — which
    # silently broke MachineGuid collision detection. Colour only when stderr
    # is an interactive terminal.
    if [[ -t 2 ]]; then
        case "${level}" in
            WARN)  printf '\033[33m%s\033[0m\n' "${line}" >&2 ;;
            ERROR) printf '\033[31m%s\033[0m\n' "${line}" >&2 ;;
            OK)    printf '\033[32m%s\033[0m\n' "${line}" >&2 ;;
            STEP)  printf '\033[36m%s\033[0m\n' "${line}" >&2 ;;
            *)     printf '%s\n' "${line}" >&2 ;;
        esac
    else
        printf '%s\n' "${line}" >&2
    fi

    # Mirror every line to the transcript file.
    if [[ -n "${_SCRIPT_LOG_FILE}" ]]; then
        printf '%s\n' "${line}" >> "${_SCRIPT_LOG_FILE}" 2>/dev/null || true
    fi
}

log_info()  { _log INFO  "$@"; }
log_step()  { _log STEP  "$@"; }
log_ok()    { _log OK    "$@"; }
log_warn()  { _log WARN  "$@"; }
log_error() { _log ERROR "$@"; }

# Create the transcript log file inside LOG_DIRECTORY. A missing directory is
# created 0700 and the log file 0600; an existing directory keeps its mode.
start_transcript() {
    local dir="${LOG_DIRECTORY}"
    ( umask 077 && mkdir -p "${dir}" ) 2>/dev/null || {
        log_warn "Could not create [${dir}]; file logging disabled."
        return
    }
    local ts
    ts="$(date '+%Y%m%d_%H%M%S')"
    _SCRIPT_LOG_FILE="${dir}/LGAgentScript_${ts}.log"
    ( umask 077 && : > "${_SCRIPT_LOG_FILE}" ) 2>/dev/null || { _SCRIPT_LOG_FILE=""; return; }
    log_info "Transcript logging started at [${_SCRIPT_LOG_FILE}]."
}

# Remove the private working directory and the wget auth config on every
# exit path, including an exit or a TERM/INT/HUP signal in the middle of an
# API call.
# shellcheck disable=SC2329  # invoked by the EXIT trap below
_cleanup() {
    if [[ -n "${_WGET_CONFIG_FILE}" ]]; then
        rm -f -- "${_WGET_CONFIG_FILE}"
    fi
    if [[ -n "${_WORK_DIR}" && -d "${_WORK_DIR}" ]]; then
        rm -rf -- "${_WORK_DIR}"
    fi
}
trap _cleanup EXIT

# ============================================================
# SECRET MASKING
# ============================================================

mask_secret() {
    local value="$1"
    local len="${#value}"
    if [[ -z "${value}" ]]; then printf '(empty)'; return; fi
    if [[ "${len}" -le 8 ]]; then printf '%*s' "${len}" '' | tr ' ' '*'; return; fi
    printf '%s****%s' "${value:0:4}" "${value: -4}"
}

print_config_snapshot() {
    log_step "=== Liongard Agent Config Snapshot ==="
    log_info "InstancePrefix              : ${INSTANCE_PREFIX}"
    log_info "ApiTokenKey (masked)        : $(mask_secret "${API_TOKEN_KEY}")"
    log_info "ApiTokenSecret (masked)     : $(mask_secret "${API_TOKEN_SECRET}")"
    log_info "AgentTokenKey (masked)      : $(mask_secret "${AGENT_TOKEN_KEY}")"
    log_info "AgentTokenSecret (masked)   : $(mask_secret "${AGENT_TOKEN_SECRET}")"
    log_info "Environment                 : ${ENVIRONMENT}"
    log_info "AgentDescription            : ${AGENT_DESCRIPTION}"
    log_info "IncludeEnvironmentValue     : ${INCLUDE_ENVIRONMENT_VALUE}"
    log_info "EnableEnvironmentMatching   : ${ENABLE_ENVIRONMENT_MATCHING}"
    log_info "CreateEnvironmentIfMissing  : ${CREATE_ENVIRONMENT_IF_MISSING}"
    log_info "RemoveAgentFromPlatform     : ${REMOVE_AGENT_FROM_PLATFORM}"
    log_info "LogDirectory                : ${LOG_DIRECTORY}"
    log_info "LinuxArchitecture           : ${LINUX_ARCHITECTURE}"
    log_info "InstallerUrl                : ${INSTALLER_URL}"
    log_info "ApiFailureBehavior          : ${API_FAILURE_BEHAVIOR}"
    log_step "======================================"
}

# ============================================================
# CONFIGURATION VALIDATION
# ============================================================

assert_config_value() {
    local name="$1"
    local value="$2"
    if [[ -z "${value}" || "${value}" == REPLACE_WITH_* ]]; then
        log_error "Configuration value [${name}] must be provided before running this script."
        exit 2
    fi
}

validate_config() {
    log_step "Validating configuration..."
    assert_config_value "INSTANCE_PREFIX"    "${INSTANCE_PREFIX}"
    # Catch placeholder-style wildcard characters (for example the old "us?" default).
    if [[ "${INSTANCE_PREFIX}" == *[?*[\]]* ]]; then
        log_error "INSTANCE_PREFIX '${INSTANCE_PREFIX}' contains a placeholder character. Provide a valid instance prefix (e.g. us1, eu2)."
        exit 2
    fi
    assert_config_value "API_TOKEN_KEY"      "${API_TOKEN_KEY}"
    assert_config_value "API_TOKEN_SECRET"   "${API_TOKEN_SECRET}"
    assert_config_value "AGENT_TOKEN_KEY"    "${AGENT_TOKEN_KEY}"
    assert_config_value "AGENT_TOKEN_SECRET" "${AGENT_TOKEN_SECRET}"
    if [[ "${INCLUDE_ENVIRONMENT_VALUE}" == true ]]; then
        assert_config_value "ENVIRONMENT"    "${ENVIRONMENT}"
    fi
    if [[ -n "${DOWNLOAD_DIRECTORY}" ]]; then
        log_warn "DOWNLOAD_DIRECTORY is deprecated and no longer used. The installer downloads to a private temporary directory, and the log goes to LOG_DIRECTORY [${LOG_DIRECTORY}]."
    fi
    if [[ -n "${ENABLE_PRE_UNINSTALL}" ]]; then
        log_warn "ENABLE_PRE_UNINSTALL is deprecated and no longer used. A healthy agent is never removed (it's upgraded only when the installer is newer), and a stale install is always cleaned up before installing."
    fi
    if [[ "${MINIMUM_REMOTE_DELETION_SCORE}" != "50" ]]; then
        log_warn "MINIMUM_REMOTE_DELETION_SCORE is deprecated and ignored. Remote deletion now needs exactly one agent with the same environment and hostname."
    fi
    log_ok "Configuration validated."
}

# ============================================================
# INSTALLER URL (by CPU architecture)
# Sets INSTALLER_URL from LINUX_ARCHITECTURE unless it was set explicitly.
# ============================================================

resolve_installer_url() {
    local arch="${LINUX_ARCHITECTURE,,}"
    local machine

    case "${arch}" in
        auto|x64|arm64) ;;
        *)
            log_error "LINUX_ARCHITECTURE must be auto, x64 or arm64 (got '${LINUX_ARCHITECTURE}')."
            exit 2
            ;;
    esac

    if [[ -n "${INSTALLER_URL}" ]]; then
        log_info "Using the configured INSTALLER_URL; LINUX_ARCHITECTURE is ignored."
        return 0
    fi

    if [[ "${arch}" == auto ]]; then
        machine="$(uname -m 2>/dev/null || printf 'unknown')"
        case "${machine}" in
            x86_64)  arch="x64" ;;
            aarch64) arch="arm64" ;;
            *)
                log_error "Unsupported CPU architecture '${machine}' (uname -m). The Liongard Agent installer is available for x86_64 and aarch64 only."
                exit 3
                ;;
        esac
        log_info "CPU architecture: ${machine} → ${arch}"
    else
        log_info "CPU architecture forced by LINUX_ARCHITECTURE: ${arch}"
    fi

    INSTALLER_URL="https://agents.static.liongard.com/LiongardAgent-lts-${arch}.xz.run"
}

# ============================================================
# INSTANCE PREFIX NORMALIZATION
# Accepts: us1 | us1.app.liongard.com | https://us1.app.liongard.com
#          (any case, http:// or https://, surrounding spaces, trailing slash or path)
# Exits 2 unless the result is letters, digits and hyphens only.
# Sets:    _INSTANCE_HOST, _INSTANCE_BASE_URL
# ============================================================

resolve_instance_prefix() {
    local raw="${INSTANCE_PREFIX}"
    local sanitized

    # Trim surrounding whitespace and lowercase.
    sanitized="${raw#"${raw%%[![:space:]]*}"}"
    sanitized="${sanitized%"${sanitized##*[![:space:]]}"}"
    sanitized="${sanitized,,}"
    # Strip URL scheme if present.
    sanitized="${sanitized#https://}"
    sanitized="${sanitized#http://}"
    # Strip any path (and trailing slash) after the host.
    sanitized="${sanitized%%/*}"

    # If it looks like a full hostname, extract only the first label.
    if [[ "${sanitized}" == *".app.liongard.com" ]]; then
        sanitized="${sanitized%%.*}"
    fi

    if [[ ! "${sanitized}" =~ ^[A-Za-z0-9-]+$ ]]; then
        log_error "INSTANCE_PREFIX '${raw}' is not a Liongard instance such as us1, us1.app.liongard.com or https://us1.app.liongard.com."
        exit 2
    fi

    INSTANCE_PREFIX="${sanitized}"
    _INSTANCE_HOST="${INSTANCE_PREFIX}.app.liongard.com"
    _INSTANCE_BASE_URL="https://${_INSTANCE_HOST}/api/v1"
    log_info "Liongard instance: ${_INSTANCE_HOST}"
}

# ============================================================
# PREREQUISITE CHECKS
# ============================================================

_has_cmd() {
    command -v "$1" &>/dev/null
}

check_root() {
    local uid
    uid="${EUID:-$(id -u 2>/dev/null || printf '1')}"
    if [[ "${uid}" -ne 0 ]]; then
        log_error "This script must be run as root or via sudo."
        exit 3
    fi
}

check_prerequisites() {
    log_step "Checking prerequisites..."

    # HTTP client — prefer curl, fall back to wget.
    if _has_cmd curl; then
        _HTTP_CLIENT="curl"
    elif _has_cmd wget; then
        _HTTP_CLIENT="wget"
    else
        log_error "Neither curl nor wget is available. Install one and retry."
        exit 3
    fi
    log_info "HTTP client: ${_HTTP_CLIENT}"

    # Core utilities that must exist.
    local -a missing=()
    for cmd in sed awk grep hostname; do
        _has_cmd "${cmd}" || missing+=("${cmd}")
    done
    if [[ "${#missing[@]}" -gt 0 ]]; then
        log_error "Missing required commands: ${missing[*]}"
        exit 3
    fi

    # jq is required when environment matching or remote deletion is on.
    local need_jq=false
    [[ "${INCLUDE_ENVIRONMENT_VALUE}" == true && "${ENABLE_ENVIRONMENT_MATCHING}" == true ]] && need_jq=true
    [[ "${REMOVE_AGENT_FROM_PLATFORM}" == true ]] && need_jq=true
    if [[ "${need_jq}" == true ]] && ! _has_cmd jq; then
        log_error "jq is required when EnableEnvironmentMatching=true or RemoveAgentFromPlatform=true. Install jq and retry."
        exit 3
    fi

    # Init system detection (informational; the script adapts at runtime).
    if _has_cmd systemctl; then
        log_info "Init system: systemd"
    elif _has_cmd service; then
        log_info "Init system: SysV (service command)"
    else
        log_warn "Neither systemctl nor service found; service management will be limited."
    fi

    log_ok "Prerequisites satisfied."
}

# ============================================================
# DISTRIBUTION AND PACKAGE MANAGER DETECTION
# ============================================================

detect_distro() {
    log_step "Detecting Linux distribution and package manager..."

    local os_id="" os_like=""
    if [[ -f /etc/os-release ]]; then
        # Source selectively to avoid polluting the shell environment.
        os_id="$(. /etc/os-release 2>/dev/null; printf '%s' "${ID:-}")"
        os_like="$(. /etc/os-release 2>/dev/null; printf '%s' "${ID_LIKE:-}")"
    fi

    # Determine package manager by probing available commands in family order.
    if _has_cmd dpkg && { [[ "${os_id}" == "debian" || "${os_id}" == "ubuntu" \
                           || "${os_like}" == *"debian"* ]]; }; then
        _PKG_TYPE="deb"
        _PKG_MANAGER="$(_has_cmd apt-get && printf 'apt' || printf 'dpkg')"
    elif _has_cmd zypper; then
        _PKG_TYPE="rpm"; _PKG_MANAGER="zypper"
    elif _has_cmd dnf; then
        _PKG_TYPE="rpm"; _PKG_MANAGER="dnf"
    elif _has_cmd yum; then
        _PKG_TYPE="rpm"; _PKG_MANAGER="yum"
    elif _has_cmd rpm; then
        _PKG_TYPE="rpm"; _PKG_MANAGER="rpm"
    elif _has_cmd dpkg; then
        _PKG_TYPE="deb"; _PKG_MANAGER="dpkg"
    else
        log_warn "Could not detect a known package manager; will infer type from URL extension."
    fi

    # Override / set _PKG_TYPE from the installer URL extension when the
    # URL is more specific than the probed package manager.
    # The last extension of the URL filename is extracted with ##*. — so for
    # LiongardAgent-lts-x64.xz.run that yields "run", not "xz.run".
    local url_ext="${INSTALLER_URL##*.}"
    case "${url_ext,,}" in
        deb|rpm|sh) _PKG_TYPE="${url_ext,,}" ;;
        # Makeself self-extracting archives (.run, .bin) are executed directly
        # like shell scripts; they must NOT be passed to dpkg/rpm.
        run|bin)    _PKG_TYPE="sh" ;;
    esac

    if [[ -z "${_PKG_TYPE}" ]]; then
        log_error "Cannot determine installer type. Set INSTALLER_URL to a .deb, .rpm, .sh, .run, or .bin file."
        exit 3
    fi

    log_info "OS: ${os_id:-unknown} (family: ${os_like:-none})"
    log_info "Package type: ${_PKG_TYPE} | Manager: ${_PKG_MANAGER:-unknown}"
}

# ============================================================
# MACHINE IDENTIFIER (Linux analogue of Windows MachineGuid)
#
# Priority order:
#   1. /etc/machine-id
#   2. /var/lib/dbus/machine-id
#   3. hostnamectl Machine ID field
#   4. /sys/class/dmi/id/product_uuid
#   5. dmidecode -s system-uuid
#
# Returns the identifier on stdout; exits 1 if no valid source found.
# NOTE: This script NEVER modifies /etc/machine-id or any system ID file.
# ============================================================

_normalize_id() {
    # Trim whitespace, strip braces, lowercase.
    printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -d '{}' | tr '[:upper:]' '[:lower:]'
}

_is_placeholder_id() {
    case "$1" in
        ""|"00000000-0000-0000-0000-000000000000" \
        |"ffffffff-ffff-ffff-ffff-ffffffffffff"   \
        |"not set"|"none"|"unknown") return 0 ;;
        *) return 1 ;;
    esac
}

get_local_machine_id() {
    local raw id

    # 1. /etc/machine-id
    if [[ -f /etc/machine-id ]]; then
        raw="$(cat /etc/machine-id 2>/dev/null)"
        id="$(_normalize_id "${raw}")"
        if ! _is_placeholder_id "${id}"; then
            log_info "Machine ID source: /etc/machine-id"
            printf '%s' "${id}"; return 0
        fi
    fi

    # 2. /var/lib/dbus/machine-id
    if [[ -f /var/lib/dbus/machine-id ]]; then
        raw="$(cat /var/lib/dbus/machine-id 2>/dev/null)"
        id="$(_normalize_id "${raw}")"
        if ! _is_placeholder_id "${id}"; then
            log_info "Machine ID source: /var/lib/dbus/machine-id"
            printf '%s' "${id}"; return 0
        fi
    fi

    # 3. hostnamectl
    if _has_cmd hostnamectl; then
        raw="$(hostnamectl 2>/dev/null | awk '/Machine ID[[:space:]]*:/{print $NF}')"
        id="$(_normalize_id "${raw}")"
        if ! _is_placeholder_id "${id}"; then
            log_info "Machine ID source: hostnamectl"
            printf '%s' "${id}"; return 0
        fi
    fi

    # 4. /sys/class/dmi/id/product_uuid
    if [[ -r /sys/class/dmi/id/product_uuid ]]; then
        raw="$(cat /sys/class/dmi/id/product_uuid 2>/dev/null)"
        id="$(_normalize_id "${raw}")"
        if ! _is_placeholder_id "${id}"; then
            log_info "Machine ID source: /sys/class/dmi/id/product_uuid"
            printf '%s' "${id}"; return 0
        fi
    fi

    # 5. dmidecode
    if _has_cmd dmidecode; then
        raw="$(dmidecode -s system-uuid 2>/dev/null | head -1)"
        id="$(_normalize_id "${raw}")"
        if ! _is_placeholder_id "${id}"; then
            log_info "Machine ID source: dmidecode"
            printf '%s' "${id}"; return 0
        fi
    fi

    log_error "Unable to determine a stable machine identifier. All sources returned empty or placeholder values."
    exit 1
}

# ============================================================
# LOCAL HOST IDENTITY COLLECTION
# ============================================================

get_local_hostnames() {
    # Collect hostname variants into a newline-delimited list on stdout,
    # deduplicated case-insensitively. 15-character truncations are also
    # included for parity with Windows NETBIOS matching behaviour.
    local -A seen=()
    local -a names=()
    local -a raw=()

    # Gather raw candidates from all available sources.
    local n
    [[ -f /etc/hostname ]] && { n="$(tr -d '[:space:]' < /etc/hostname 2>/dev/null)"; [[ -n "${n}" ]] && raw+=("${n}"); }
    n="$(hostname 2>/dev/null)"    && [[ -n "${n}" ]] && raw+=("${n}") || true
    n="$(hostname -s 2>/dev/null)" && [[ -n "${n}" ]] && raw+=("${n}") || true
    n="$(hostname -f 2>/dev/null)" && [[ -n "${n}" ]] && raw+=("${n}") || true

    # Deduplicate and add 15-char truncations in a single loop.
    local v lc trunc tlc
    for v in "${raw[@]}"; do
        [[ -z "${v}" ]] && continue
        lc="$(printf '%s' "${v}" | tr '[:upper:]' '[:lower:]')"
        if [[ -z "${seen[${lc}]+_}" ]]; then
            seen["${lc}"]=1
            names+=("${v}")
        fi
        if [[ "${#v}" -gt 15 ]]; then
            trunc="${v:0:15}"
            tlc="$(printf '%s' "${trunc}" | tr '[:upper:]' '[:lower:]')"
            if [[ -z "${seen[${tlc}]+_}" ]]; then
                seen["${tlc}"]=1
                names+=("${trunc}")
            fi
        fi
    done

    [[ "${#names[@]}" -gt 0 ]] && printf '%s\n' "${names[@]}"
    return 0
}

# ============================================================
# LIONGARD API HELPERS
# ============================================================

# Build the base64-encoded auth token (key:secret) and store it in
# _AUTH_HEADER_VALUE. Never prints the encoded value.
# The token never goes on a command line, where it would show in the process
# list: curl reads it from a config on stdin (see _curl_auth_config). wget
# cannot read headers from stdin, so for wget it is written once to a mktemp
# file (mode 0600) passed through WGETRC and removed by the EXIT trap.
build_auth_header() {
    local raw="${API_TOKEN_KEY}:${API_TOKEN_SECRET}"
    _AUTH_HEADER_VALUE="$(printf '%s' "${raw}" | base64 | tr -d '\n')"

    if [[ "${_HTTP_CLIENT}" == "wget" && -z "${_WGET_CONFIG_FILE}" ]]; then
        _WGET_CONFIG_FILE="$(mktemp "${TMPDIR:-/tmp}/liongard-wgetrc.XXXXXXXX" 2>/dev/null)" || {
            _WGET_CONFIG_FILE=""
            log_error "Cannot create a private wget config file under [${TMPDIR:-/tmp}]."
            exit 4
        }
        printf 'header = X-ROAR-API-KEY: %s\n' "${_AUTH_HEADER_VALUE}" > "${_WGET_CONFIG_FILE}"
    fi
}

# Print the curl config line that carries the auth header. Pipe it to
# `curl --config -`; printf is a shell builtin, so no process sees the token.
_curl_auth_config() {
    printf 'header = "X-ROAR-API-KEY: %s"\n' "${_AUTH_HEADER_VALUE}"
}

# Perform an authenticated GET request.
# Usage: _api_get <path>  → prints response body; returns non-zero on HTTP error.
_api_get() {
    local path="$1"
    local url="${_INSTANCE_BASE_URL}${path}"

    if [[ "${_HTTP_CLIENT}" == "curl" ]]; then
        _curl_auth_config | curl -sSL --fail --config - \
            -H "User-Agent: LiongardLinuxAgentInstaller/1.0" \
            "${url}"
    else
        # WGETRC replaces only the per-user ~/.wgetrc; the system wgetrc
        # (proxy settings and so on) is still read.
        WGETRC="${_WGET_CONFIG_FILE}" wget -qO- \
            --header="User-Agent: LiongardLinuxAgentInstaller/1.0" \
            "${url}"
    fi
}

# Perform an authenticated POST with a JSON body.
# Usage: _api_post_json <path> <json>  → prints response body; returns non-zero on HTTP error.
_api_post_json() {
    local path="$1"
    local body="$2"
    local url="${_INSTANCE_BASE_URL}${path}"

    if [[ "${_HTTP_CLIENT}" == "curl" ]]; then
        _curl_auth_config | curl -sSL --fail --config - \
            -X POST \
            -H "Content-Type: application/json" \
            -H "User-Agent: LiongardLinuxAgentInstaller/1.0" \
            --data-binary "${body}" \
            "${url}"
    else
        WGETRC="${_WGET_CONFIG_FILE}" wget -qO- \
            --header="Content-Type: application/json" \
            --header="User-Agent: LiongardLinuxAgentInstaller/1.0" \
            --post-data="${body}" \
            "${url}"
    fi
}

# Perform an authenticated DELETE and return only the HTTP status code.
_api_delete() {
    local path="$1"
    local url="${_INSTANCE_BASE_URL}${path}"

    if [[ "${_HTTP_CLIENT}" != "curl" ]]; then
        log_warn "wget does not natively support HTTP DELETE; remote agent deletion skipped."
        printf '0'; return 1
    fi

    _curl_auth_config | curl -sSL -o /dev/null -w '%{http_code}' --config - \
        -X DELETE \
        -H "User-Agent: LiongardLinuxAgentInstaller/1.0" \
        "${url}"
}

# URL-encode a string (RFC 3986).
url_encode() {
    local string="$1" encoded="" char i
    local length="${#string}"
    for (( i = 0; i < length; i++ )); do
        char="${string:i:1}"
        case "${char}" in
            [a-zA-Z0-9.~_-]) encoded+="${char}" ;;
            *) encoded+="$(printf '%%%02X' "'${char}")" ;;
        esac
    done
    printf '%s' "${encoded}"
}

# ============================================================
# ENVIRONMENT NAME NORMALIZATION AND MATCHING
# ============================================================

normalize_env_name() {
    local raw="$1"
    # Trim leading/trailing whitespace.
    local trimmed
    trimmed="$(printf '%s' "${raw}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    # Remove leading articles (the, a, an — case-insensitive).
    trimmed="$(printf '%s' "${trimmed}" | sed 's/^[Tt][Hh][Ee][[:space:]]\+//;s/^[Aa][Nn]\?[[:space:]]\+//')"
    # Strip all non-alphanumeric characters then uppercase.
    printf '%s' "${trimmed}" | tr -cd 'a-zA-Z0-9' | tr 'a-z' 'A-Z'
}

# Resolve ENVIRONMENT against the Liongard API using progressive matching.
# Usage: resolve_environment_name [exact-only]
#   exact-only → only the exact case-insensitive match counts (used with
#   CREATE_ENVIRONMENT_IF_MISSING=true).
# Returns 0 and sets _RESOLVED_ENVIRONMENT on a match; otherwise logs a warning
# and returns 1 (no such environment, including a name too short to match
# loosely), 2 (ambiguous) or 3 (the API call failed).
resolve_environment_name() {
    local exact_only="${1:-}"
    local input_name="${ENVIRONMENT}"
    local input_norm
    input_norm="$(normalize_env_name "${input_name}")"

    log_step "Resolving environment '${input_name}' against Liongard API..."

    local response
    if ! response="$(_api_get "/environments" 2>/dev/null)"; then
        log_warn "Could not retrieve Liongard environments from API."
        return 3
    fi
    if ! printf '%s' "${response}" | jq empty >/dev/null 2>&1; then
        log_warn "The Liongard environments API returned a response that is not JSON."
        return 3
    fi

    # Extract environment name values from common response shapes.
    # Handles top-level array or object with data/items/results/value key.
    local names_raw
    names_raw="$(printf '%s' "${response}" | jq -r '
        (if   type == "array" then .
         elif .data    then .data
         elif .items   then .items
         elif .results then .results
         elif .value   then .value
         else [.]
         end)
        | .[]
        | (.Name // .DisplayName // .EnvironmentName // .name // .displayName // "")
        | select(length > 0)
    ' 2>/dev/null)"

    if [[ -z "${names_raw}" ]]; then
        log_warn "The Liongard environments API returned no environment names."
        return 1
    fi

    local -a env_names=()
    while IFS= read -r line; do
        [[ -n "${line}" ]] && env_names+=("${line}")
    done <<< "${names_raw}"

    local input_lower
    input_lower="$(printf '%s' "${input_name}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr '[:upper:]' '[:lower:]')"

    # 1. Exact case-insensitive match.
    local name name_lower
    for name in "${env_names[@]}"; do
        name_lower="$(printf '%s' "${name}" | tr '[:upper:]' '[:lower:]')"
        if [[ "${name_lower}" == "${input_lower}" ]]; then
            log_info "Environment exact match: '${input_name}' → '${name}'"
            _RESOLVED_ENVIRONMENT="${name}"; return 0
        fi
    done

    if [[ "${exact_only}" == "exact-only" ]]; then
        log_warn "No Liongard environment is named exactly '${input_name}' (exact match only because CREATE_ENVIRONMENT_IF_MISSING=true)."
        return 1
    fi

    # The remaining passes need a normalized name long enough to match reliably.
    if [[ "${#input_norm}" -lt 4 ]]; then
        log_warn "Environment '${input_name}' normalizes to '${input_norm}' — too short for reliable matching (min 4 chars)."
        return 1
    fi

    # Helper: build arrays of names whose normalized value equals input_norm,
    # shares a prefix, or contains input_norm (bi-directionally).
    local -a norm_matches=() prefix_matches=() contains_matches=()
    local norm
    for name in "${env_names[@]}"; do
        norm="$(normalize_env_name "${name}")"
        [[ -z "${norm}" ]] && continue
        if [[ "${norm}" == "${input_norm}" ]]; then
            norm_matches+=("${name}")
        elif [[ "${norm}" == "${input_norm}"* || "${input_norm}" == "${norm}"* ]]; then
            prefix_matches+=("${name}")
        elif [[ "${norm}" == *"${input_norm}"* || "${input_norm}" == *"${norm}"* ]]; then
            contains_matches+=("${name}")
        fi
    done

    # 2. Single normalized match.
    if [[ "${#norm_matches[@]}" -eq 1 ]]; then
        log_info "Environment normalized match: '${input_name}' → '${norm_matches[0]}'"
        _RESOLVED_ENVIRONMENT="${norm_matches[0]}"; return 0
    elif [[ "${#norm_matches[@]}" -gt 1 ]]; then
        log_warn "Ambiguous normalized environment match for '${input_name}'. Candidates: ${norm_matches[*]}"
        return 2
    fi

    # 3. Single prefix match.
    if [[ "${#prefix_matches[@]}" -eq 1 ]]; then
        log_info "Environment prefix match: '${input_name}' → '${prefix_matches[0]}'"
        _RESOLVED_ENVIRONMENT="${prefix_matches[0]}"; return 0
    elif [[ "${#prefix_matches[@]}" -gt 1 ]]; then
        log_warn "Ambiguous prefix environment match for '${input_name}'. Candidates: ${prefix_matches[*]}"
        return 2
    fi

    # 4. Single contains match.
    if [[ "${#contains_matches[@]}" -eq 1 ]]; then
        log_info "Environment contains match: '${input_name}' → '${contains_matches[0]}'"
        _RESOLVED_ENVIRONMENT="${contains_matches[0]}"; return 0
    elif [[ "${#contains_matches[@]}" -gt 1 ]]; then
        log_warn "Ambiguous contains environment match for '${input_name}'. Candidates: ${contains_matches[*]}"
        return 2
    fi

    # 5. No match.
    local sample
    sample="$(printf '%s\n' "${env_names[@]:0:5}" | tr '\n' ';' | sed 's/;$//' | sed 's/;/; /g')"
    log_warn "No Liongard environment matched '${input_name}' (normalized '${input_norm}'). Sample known names: ${sample}"
    return 1
}

# Create ENVIRONMENT (trimmed) through the API: POST /environments with
# {"Name": "<name>"}. The API token must be allowed to create environments.
# On success: sets _RESOLVED_ENVIRONMENT to the created name and returns 0.
# On failure: logs a warning and returns 1.
create_environment() {
    local name body response created
    name="$(printf '%s' "${ENVIRONMENT}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    body="$(jq -cn --arg n "${name}" '{Name: $n}')"

    log_step "Creating environment '${name}' in Liongard (CREATE_ENVIRONMENT_IF_MISSING=true)..."
    if ! response="$(_api_post_json "/environments" "${body}" 2>/dev/null)"; then
        log_warn "Could not create environment '${name}' in Liongard (check that the API token may create environments)."
        return 1
    fi

    created="$(printf '%s' "${response}" | jq -r '
        (if type == "array" then .[0] else . end)
        | (.Name // .name // empty)
    ' 2>/dev/null)" || created=""
    _RESOLVED_ENVIRONMENT="${created:-${name}}"
    log_ok "Created environment in Liongard: '${_RESOLVED_ENVIRONMENT}'"
    return 0
}

# ============================================================
# LIONGARD AGENT API QUERY
# ============================================================

# Returns agent records matching a conditions filter on stdout.
# Prints '[]' and returns 1 on failure.
get_agents_filtered() {
    local conditions="$1"
    local encoded
    encoded="$(url_encode "${conditions}")"

    log_info "Querying Liongard agents: ${conditions}"

    local response
    if ! response="$(_api_get "/agents?conditions=${encoded}" 2>/dev/null)"; then
        log_warn "Agent API lookup failed."
        printf '[]'; return 1
    fi

    # Normalise to a JSON array regardless of response shape.
    if _has_cmd jq; then
        local normalised
        normalised="$(printf '%s' "${response}" | jq -c '
            if type == "array" then .
            elif .data    then .data
            elif .items   then .items
            elif .results then .results
            else [.]
            end
        ' 2>/dev/null)" || normalised="[]"
        printf '%s' "${normalised}"
    else
        # jq not available — return raw response; callers handle absence of jq.
        printf '%s' "${response}"
    fi
    return 0
}

# Stops the run before anything changes when the API token doesn't work, so a
# bad token or an unreachable instance never leaves the machine without an agent.
# With "warn" (a healthy install, which the script changes without the API) a
# failure is logged and the run continues.
check_api_access() {
    local mode="${1:-}"
    log_step "Checking access to the Liongard API..."
    if ! _api_get "/environments" >/dev/null 2>&1; then
        if [[ "${mode}" == "warn" ]]; then
            log_warn "The Liongard API call failed. Check API_TOKEN_KEY, API_TOKEN_SECRET and HTTPS access to ${_INSTANCE_HOST}. A healthy agent doesn't need the API, so the run continues."
            return 0
        fi
        log_error "The Liongard API call failed. Check API_TOKEN_KEY, API_TOKEN_SECRET and HTTPS access to ${_INSTANCE_HOST}. Nothing was changed. Aborting."
        exit 4
    fi
    log_ok "Liongard API access confirmed."
}

# ============================================================
# COLLISION DETECTION AND DEVICEID OVERRIDE
#
# If the local machine ID already exists in Liongard under a DIFFERENT
# hostname, a fresh UUID is generated for the DEVICEID install property.
# This prevents the new agent from overwriting an unrelated existing record.
# The script NEVER modifies /etc/machine-id.
# ============================================================

_generate_uuid() {
    if _has_cmd uuidgen; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    elif [[ -r /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid | tr '[:upper:]' '[:lower:]'
    else
        log_error "Cannot generate UUID: uuidgen is missing and /proc/sys/kernel/random/uuid is unavailable."
        exit 1
    fi
}

# Sets _DEVICE_GUID_OVERRIDE when a collision with a different host is found.
resolve_device_guid_override() {
    local local_machine_id="$1"
    local agents_json="$2"
    shift 2
    local -a local_hostnames=("$@")

    # No agents returned → no collision possible.
    if [[ -z "${agents_json}" || "${agents_json}" == "[]" || "${agents_json}" == "null" ]]; then
        log_info "No existing agents for this machine ID; no DEVICEID override required."
        return 0
    fi

    if ! _has_cmd jq; then
        log_warn "jq not available; collision detection skipped. Install jq for full collision detection."
        return 0
    fi

    # Re-verify the MachineGuid client-side rather than trusting that the API
    # honoured the server-side 'MachineGuid = ...' condition. Without this guard,
    # an API that ignored the filter and returned unrelated agents would look
    # like a hostname mismatch and trigger a spurious override.
    local matched_json
    matched_json="$(printf '%s' "${agents_json}" | jq -c \
        --arg mid "${local_machine_id}" \
        '[.[] | select((.MachineGuid // "" | ascii_downcase) == ($mid | ascii_downcase))]' 2>/dev/null)" \
        || matched_json="[]"

    local agent_count
    agent_count="$(printf '%s' "${matched_json}" | jq 'length' 2>/dev/null)" || agent_count=0

    if [[ "${agent_count}" -eq 0 ]]; then
        log_info "No agents with a matching MachineGuid; no DEVICEID override required."
        return 0
    fi

    log_info "Found ${agent_count} Liongard agent record(s) matching this machine ID."

    # Check whether any returned agent matches the local hostname/FQDN.
    local hostname_matched=false
    local agent_hostname agent_fqdn h h_lower
    while IFS= read -r agent_json; do
        [[ -z "${agent_json}" || "${agent_json}" == "null" ]] && continue
        agent_hostname="$(printf '%s' "${agent_json}" | jq -r '.Hostname // .Name // "" | ascii_downcase' 2>/dev/null)"
        agent_fqdn="$(printf '%s' "${agent_json}" | jq -r '(.Data.FQDN // "") | ascii_downcase' 2>/dev/null)"

        for h in "${local_hostnames[@]}"; do
            h_lower="$(printf '%s' "${h}" | tr '[:upper:]' '[:lower:]')"
            if [[ -n "${agent_hostname}" && "${h_lower}" == "${agent_hostname}" ]] || \
               [[ -n "${agent_fqdn}"    && "${h_lower}" == "${agent_fqdn}" ]]; then
                hostname_matched=true
                break 2
            fi
        done
    done < <(printf '%s' "${matched_json}" | jq -c '.[]' 2>/dev/null)

    if [[ "${hostname_matched}" == true ]]; then
        log_info "Existing agent matches this machine ID and hostname — no DEVICEID override required (likely a reinstall)."
        return 0
    fi

    # Collision: same machine ID, different hostname → generate override.
    local other_hosts
    other_hosts="$(printf '%s' "${matched_json}" | jq -r '[.[].Hostname // .[].Name // ""] | join(", ")' 2>/dev/null)"
    log_warn "Machine ID [${local_machine_id}] is registered in Liongard under different hostname(s): ${other_hosts}"
    log_warn "Generating a DEVICEID override to prevent overwriting the existing record."

    _DEVICE_GUID_OVERRIDE="$(_generate_uuid)"
    log_ok "DEVICEID override generated: ${_DEVICE_GUID_OVERRIDE}"
}

# ============================================================
# REMOTE PLATFORM AGENT DELETION
#
# A platform record is deleted only when exactly one agent matches both:
#   - environment: the agent's environment equals the resolved environment
#     (case-insensitive), or neither has one;
#   - hostname: the agent's Hostname, Name or Data.FQDN equals one of the
#     names from get_deletion_hostnames (case-insensitive, whole string).
# The machine ID and MAC addresses are not used. With zero or several matches
# the deletion is skipped and every candidate is logged.
# ============================================================

# Names this machine can be registered under, one per line: `hostname` (the
# name run_installer registers as LIONGARDAGENTNAME), the short host name and
# the FQDN. No truncated variants; "localhost" is never used.
get_deletion_hostnames() {
    local -A seen=()
    local n lc
    for n in "$(hostname 2>/dev/null || true)" "$(hostname -s 2>/dev/null || true)" "$(hostname -f 2>/dev/null || true)"; do
        n="${n%.}"
        if [[ -z "${n}" ]]; then continue; fi
        lc="$(printf '%s' "${n}" | tr '[:upper:]' '[:lower:]')"
        if [[ "${lc}" == "localhost" || "${lc}" == "localhost.localdomain" || -n "${seen[${lc}]+_}" ]]; then continue; fi
        seen["${lc}"]=1
        printf '%s\n' "${n}"
    done
    return 0
}

# Prints a JSON array of the agents whose Hostname or Name equals one of the
# given names, deduplicated by ID. The API filter only narrows the list;
# invoke_remote_agent_removal checks every candidate again, exactly.
# Returns 1 if any lookup fails, so a partial list never leads to a deletion.
get_deletion_candidates() {
    local all="[]" n escaped field batch
    for n in "$@"; do
        escaped="${n//\'/\'\'}"
        for field in Hostname Name; do
            batch="$(get_agents_filtered "${field} = '${escaped}'")" || return 1
            all="$(jq -c --argjson b "${batch}" '. + $b' <<< "${all}" 2>/dev/null)" || return 1
        done
    done
    jq -c 'unique_by(.ID // .id // tostring)' <<< "${all}" 2>/dev/null || return 1
}

# Prints the IDs of the environments named exactly $1 (case-insensitive), one
# per line. Only needed when an agent reports an environment ID without a name.
get_environment_ids() {
    local response
    if ! response="$(_api_get "/environments" 2>/dev/null)"; then
        log_warn "Could not retrieve Liongard environments from API."
        return 0
    fi
    printf '%s' "${response}" | jq -r --arg n "$1" '
        (if   type == "array" then .
         elif .data    then .data
         elif .items   then .items
         elif .results then .results
         elif .value   then .value
         else [.]
         end)
        | .[]
        | select(((.Name // .name // "") | ascii_downcase) == ($n | ascii_downcase))
        | (.ID // .id // empty) | tostring
    ' 2>/dev/null || true
}

invoke_remote_agent_removal() {
    if [[ "$#" -eq 0 ]]; then
        log_warn "Remote deletion skipped: no local hostname could be determined."
        return 0
    fi
    local -a local_hostnames=("$@")

    if ! _has_cmd jq; then
        log_warn "jq required for remote deletion matching. Skipping."
        return 0
    fi

    local wanted="${_RESOLVED_ENVIRONMENT}"
    local wanted_lc
    wanted_lc="$(printf '%s' "${wanted}" | tr '[:upper:]' '[:lower:]')"
    log_info "Remote deletion matches environment [${wanted:-(none)}] and hostname [$(IFS=', '; printf '%s' "${local_hostnames[*]}")]."

    local agents_json
    if ! agents_json="$(get_deletion_candidates "${local_hostnames[@]}")"; then
        log_warn "Remote deletion skipped: the Liongard agent lookup failed."
        return 0
    fi

    # One row per candidate: ID, names, environment and the first name that
    # equals a local name. The environment is an object with Name and ID (null
    # when the agent has none); EnvironmentName, a plain Environment string and
    # EnvironmentID are also read in case the shape differs.
    local local_json rows
    local_json="$(printf '%s\n' "${local_hostnames[@]}" | jq -R . | jq -sc 'map(ascii_downcase)')"
    rows="$(jq -c --argjson local "${local_json}" '
        .[] | select(type == "object")
        | (.Environment | type) as $et
        | {
            id:       ((.ID // .id // "") | tostring),
            names:    ([.Hostname, .Name, (.Data.FQDN? // null)] | map(select(type == "string" and length > 0))),
            env_name: ((if $et == "object" then .Environment.Name elif $et == "string" then .Environment else null end) // .EnvironmentName // ""),
            env_id:   (((if $et == "object" then .Environment.ID else null end) // .EnvironmentID // "") | tostring)
          }
        | .name_hit = (first(.names[] | select(ascii_downcase as $n | any($local[]; . == $n)))? // "")
    ' <<< "${agents_json}" 2>/dev/null)" || rows=""

    local row id names env_name env_id name_hit env_label env_ok reason
    local env_ids="" env_ids_loaded=false count=0
    local -a matched_ids=()
    while IFS= read -r row; do
        if [[ -z "${row}" ]]; then continue; fi
        count=$(( count + 1 ))
        id="$(jq -r '.id' <<< "${row}")"
        names="$(jq -r '.names | join(", ")' <<< "${row}")"
        env_name="$(jq -r '.env_name | tostring' <<< "${row}")"
        env_id="$(jq -r '.env_id' <<< "${row}")"
        name_hit="$(jq -r '.name_hit' <<< "${row}")"
        if [[ "${env_id}" == "0" ]]; then env_id=""; fi

        if [[ -n "${env_name}" ]]; then env_label="${env_name}"
        elif [[ -n "${env_id}" ]]; then env_label="ID ${env_id}"
        else env_label="(none)"
        fi

        env_ok=false
        if [[ -z "${wanted}" ]]; then
            if [[ -z "${env_name}" && -z "${env_id}" ]]; then env_ok=true; fi
        elif [[ -n "${env_name}" ]]; then
            if [[ "$(printf '%s' "${env_name}" | tr '[:upper:]' '[:lower:]')" == "${wanted_lc}" ]]; then env_ok=true; fi
        elif [[ -n "${env_id}" ]]; then
            if [[ "${env_ids_loaded}" == false ]]; then
                env_ids="$(get_environment_ids "${wanted}")"
                env_ids_loaded=true
            fi
            if grep -Fxq -- "${env_id}" <<< "${env_ids}"; then env_ok=true; fi
        fi

        reason=""
        if [[ -z "${name_hit}" ]]; then reason="no Hostname, Name or FQDN equals a local name"; fi
        if [[ "${env_ok}" != true ]]; then reason="${reason:+${reason}; }environment differs"; fi

        if [[ -z "${reason}" ]]; then
            matched_ids+=("${id}")
            log_info "  Agent ID ${id}: names [${names}], environment [${env_label}] -> match: hostname [${name_hit}] and environment match"
        else
            log_info "  Agent ID ${id}: names [${names}], environment [${env_label}] -> no match: ${reason}"
        fi
    done <<< "${rows}"
    log_info "Liongard agent candidates found: ${count}"

    if [[ "${#matched_ids[@]}" -ne 1 ]]; then
        log_warn "Remote deletion skipped: ${#matched_ids[@]} agent records match this environment and hostname, and exactly one is required. See the candidates above."
        return 0
    fi

    local agent_id="${matched_ids[0]}"
    if [[ -z "${agent_id}" ]]; then
        log_warn "Matched Liongard agent record is missing an ID; remote deletion skipped."
        return 0
    fi

    log_info "Deleting Liongard agent ID ${agent_id}..."
    local http_status
    http_status="$(_api_delete "/agents/${agent_id}")" || { log_warn "DELETE request failed."; return 0; }

    if [[ "${http_status}" == "204" || "${http_status}" == "200" ]]; then
        log_ok "Remote agent ID ${agent_id} deleted (HTTP ${http_status})."
    else
        log_warn "Unexpected HTTP ${http_status} while deleting agent ID ${agent_id}."
    fi
}

# ============================================================
# LOCAL AGENT DETECTION
# ============================================================

is_agent_installed() {
    # Returns 0 (true) if any concrete Liongard agent signal is detected.
    local svc

    # Systemd: check if the service is active, OR if a unit file backing it exists.
    # Deliberately avoid list-units --all because a just-stopped/disabled service can
    # still appear there even after daemon-reload in a "not-found" state.
    if _has_cmd systemctl; then
        for svc in "${SERVICE_NAMES[@]}"; do
            # Active check (most reliable signal).
            if systemctl is-active --quiet "${svc}" 2>/dev/null; then
                _DETECTED_SVC="${svc}"; return 0
            fi
            # Unit-file existence check (covers enabled-but-stopped, or failed state).
            local unit_dir
            for unit_dir in /etc/systemd/system /lib/systemd/system /usr/lib/systemd/system; do
                if [[ -f "${unit_dir}/${svc}.service" || -f "${unit_dir}/${svc}" ]]; then
                    _DETECTED_SVC="${svc}"; return 0
                fi
            done
        done
    fi

    # SysV service check (non-systemd hosts).
    if _has_cmd service; then
        for svc in "${SERVICE_NAMES[@]}"; do
            if service "${svc}" status &>/dev/null; then
                _DETECTED_SVC="${svc}"; return 0
            fi
        done
    fi

    # Running process check.
    local proc_name
    for proc_name in roaragent liongardagent; do
        if pgrep -x "${proc_name}" &>/dev/null; then
            log_info "Liongard process '${proc_name}' is running."
            return 0
        fi
    done
    if pgrep -f '^/opt/liongard/' &>/dev/null; then
        log_info "A process is running from /opt/liongard."
        return 0
    fi

    # Installed package check.
    if _has_cmd dpkg && dpkg -l 2>/dev/null | grep -qi liongard; then return 0; fi
    if _has_cmd rpm  && rpm  -qa 2>/dev/null | grep -qi liongard; then return 0; fi

    # Agent binary presence check. Only checks for actual executables in known
    # install locations — intentionally excludes log and config-only directories
    # which may outlive an uninstall and would produce false positives.
    local bin_path
    for bin_path in \
        /usr/local/bin/liongard-agent /usr/bin/liongard-agent \
        /usr/local/bin/roaragent      /usr/bin/roaragent \
        /usr/local/bin/liongardagent  /usr/bin/liongardagent \
        "${AGENT_BINARY_PATH}" \
        /opt/liongard/liongard-agent  /opt/liongard/bin/liongard-agent \
        /opt/liongard-agent/liongard-agent \
        /usr/local/liongard/liongard-agent; do
        [[ -f "${bin_path}" ]] && return 0
    done

    return 1
}

# ============================================================
# INSTALL STATE (Healthy / Stale / NotInstalled)
# Healthy      = the liongard-agent systemd unit is registered AND the agent
#                binary AND its config file exist. Running state isn't required.
# NotInstalled = no agent signal (is_agent_installed) and no leftover files.
# Stale        = anything else (orphaned unit, binary or folder without the rest).
# ============================================================

_core_unit_file() {
    # Prints the path of the agent's systemd unit file, if one is registered.
    local unit_dir
    for unit_dir in /etc/systemd/system /lib/systemd/system /usr/lib/systemd/system; do
        if [[ -f "${unit_dir}/${AGENT_CORE_SERVICE}.service" ]]; then
            printf '%s' "${unit_dir}/${AGENT_CORE_SERVICE}.service"
            return 0
        fi
    done
    return 1
}

_find_install_leftovers() {
    # Prints one leftover path per line: install folders and updater units that
    # invoke_liongard_agent_uninstall removes. The agent identity folder
    # (/etc/liongard-agent) is kept by design and is not a leftover.
    local path unit_dir unit_name
    for path in /opt/liongard /opt/liongard-agent /usr/local/liongard /etc/liongard; do
        if [[ -d "${path}" ]]; then printf '%s\n' "${path}"; fi
    done
    for unit_dir in /etc/systemd/system /lib/systemd/system /usr/lib/systemd/system; do
        for unit_name in liongard-agent-updater.timer liongard-agent-updater.service \
                         liongard-updater.timer; do
            if [[ -f "${unit_dir}/${unit_name}" || -L "${unit_dir}/${unit_name}" ]]; then
                printf '%s\n' "${unit_dir}/${unit_name}"
            fi
        done
    done
    return 0
}

get_install_state() {
    # Sets _INSTALL_STATE and logs the evidence it was based on.
    log_step "Checking for an existing Liongard Agent install..."

    local unit_file="" binary=false config=false detected=false leftover
    local -a leftovers=()

    unit_file="$(_core_unit_file)" || unit_file=""
    [[ -x "${AGENT_BINARY_PATH}" ]] && binary=true
    [[ -f "${AGENT_CONFIG_PATH}" ]] && config=true
    _DETECTED_SVC=""
    is_agent_installed && detected=true
    mapfile -t leftovers < <(_find_install_leftovers)

    log_info "  - Service unit '${AGENT_CORE_SERVICE}': ${unit_file:-not registered}"
    log_info "  - Agent binary ${AGENT_BINARY_PATH}: ${binary}"
    log_info "  - Agent config ${AGENT_CONFIG_PATH}: ${config}"
    log_info "  - Agent service, process, package or binary detected: ${detected}${_DETECTED_SVC:+ (service ${_DETECTED_SVC})}"
    # ${arr[@]+...} keeps set -u happy with an empty array on Bash 4.0-4.3.
    for leftover in ${leftovers[@]+"${leftovers[@]}"}; do
        log_info "  - Leftover present: ${leftover}"
    done

    if [[ -n "${unit_file}" && "${binary}" == true && "${config}" == true ]]; then
        _INSTALL_STATE="Healthy"
    elif [[ "${detected}" == false && "${#leftovers[@]}" -eq 0 ]]; then
        _INSTALL_STATE="NotInstalled"
    else
        _INSTALL_STATE="Stale"
    fi
    log_info "Install state classification: ${_INSTALL_STATE}"
}

_is_version() {
    [[ "$1" =~ ^[0-9]+(\.[0-9]+){1,3}$ ]]
}

_version_gt() {
    # Returns 0 when dotted version $1 is strictly newer than $2.
    local -a a b
    local i x y
    IFS=. read -r -a a <<< "$1"
    IFS=. read -r -a b <<< "$2"
    for (( i = 0; i < 4; i++ )); do
        x="${a[i]:-0}"; y="${b[i]:-0}"
        if (( 10#${x} > 10#${y} )); then return 0; fi
        if (( 10#${x} < 10#${y} )); then return 1; fi
    done
    return 1
}

get_installed_agent_version() {
    # Prints the AGENT_VERSION that the installer (and the agent's updater, which
    # runs the installer) records in the agent config. The file also holds the
    # agent's credentials, so only that one line is read and nothing else is logged.
    local version
    [[ -r "${AGENT_CONFIG_PATH}" ]] || return 1
    version="$(grep -m1 '^AGENT_VERSION=' "${AGENT_CONFIG_PATH}" 2>/dev/null | cut -d= -f2- | tr -d '[:space:]')" || return 1
    _is_version "${version}" || return 1
    printf '%s' "${version}"
}

get_installer_agent_version() {
    # Prints the version.txt bundled in a makeself (.run) installer, read with
    # makeself's own --tar option, which only streams the archive (startup.sh is
    # not run). Returns 1 for .deb/.rpm and for any .sh that isn't a makeself
    # archive, because running an unknown .sh with --tar could start an install.
    local pkg_file="$1" version
    [[ "${_PKG_TYPE}" == "sh" ]] || return 1
    [[ "$(sed -n 2p "${pkg_file}" 2>/dev/null)" == "# This script was generated using Makeself"* ]] || return 1
    version="$(sh "${pkg_file}" --tar xOf ./version.txt 2>/dev/null | head -n 1 | tr -d '[:space:]')" || return 1
    _is_version "${version}" || return 1
    printf '%s' "${version}"
}

# ============================================================
# STALE CLEANUP
# ============================================================

_stop_liongard_services() {
    local svc
    for svc in "${SERVICE_NAMES[@]}"; do
        if _has_cmd systemctl; then
            if systemctl is-active --quiet "${svc}" 2>/dev/null; then
                log_info "Stopping service: ${svc}"
                systemctl stop "${svc}" 2>/dev/null || log_warn "Could not stop ${svc}."
            fi
            if systemctl is-enabled --quiet "${svc}" 2>/dev/null; then
                log_info "Disabling service: ${svc}"
                systemctl disable "${svc}" 2>/dev/null || log_warn "Could not disable ${svc}."
            fi
        elif _has_cmd service; then
            service "${svc}" stop 2>/dev/null || true
        fi
    done
}

_remove_liongard_package() {
    log_info "Attempting package removal..."
    local pkg removed=false

    case "${_PKG_TYPE}" in
        deb)
            for pkg in liongard-agent roaragent liongardagent; do
                if [[ "${_PKG_MANAGER}" == "apt" ]] && _has_cmd apt-get; then
                    apt-get remove --purge -y "${pkg}" &>/dev/null && removed=true || true
                elif _has_cmd dpkg; then
                    dpkg --purge "${pkg}" &>/dev/null && removed=true || true
                fi
            done
            ;;
        rpm)
            for pkg in liongard-agent roaragent liongardagent; do
                if   _has_cmd dnf;    then dnf    remove -y "${pkg}" &>/dev/null && removed=true || true
                elif _has_cmd yum;    then yum    remove -y "${pkg}" &>/dev/null && removed=true || true
                elif _has_cmd zypper; then zypper --non-interactive remove "${pkg}" &>/dev/null && removed=true || true
                elif _has_cmd rpm;    then rpm    -e "${pkg}"         &>/dev/null && removed=true || true
                fi
            done
            ;;
    esac

    # Attempt a generic uninstall script if one exists.
    local uninstall_script
    for uninstall_script in /opt/liongard/uninstall.sh /usr/local/liongard/uninstall.sh; do
        if [[ -x "${uninstall_script}" ]]; then
            log_info "Running Liongard uninstall script: ${uninstall_script}"
            "${uninstall_script}" 2>/dev/null && removed=true || true
        fi
    done

    if [[ "${removed}" == true ]]; then
        log_ok "Package removal completed."
    else
        log_warn "No Liongard packages found via package manager (may have been installed differently)."
    fi

    # Reload systemd unit files after removal.
    _has_cmd systemctl && systemctl daemon-reload 2>/dev/null || true
}

invoke_liongard_agent_uninstall() {
    log_step "Stale cleanup: removing the existing Liongard Agent and its leftovers..."

    _stop_liongard_services
    _remove_liongard_package

    # Kill any lingering processes: by name, then anything running from
    # /opt/liongard (the LiongardAgent binary and its node and prowl children),
    # which nothing else stops once the service unit is gone.
    local proc_name
    for proc_name in roaragent liongardagent LiongardAgent; do
        if pgrep -x "${proc_name}" &>/dev/null; then
            log_info "Terminating lingering process: ${proc_name}"
            pkill -x "${proc_name}" 2>/dev/null || true
            sleep 1
        fi
    done
    if pgrep -f '^/opt/liongard/' &>/dev/null; then
        log_info "Terminating processes running from /opt/liongard"
        pkill -f '^/opt/liongard/' 2>/dev/null || true
        sleep 2
        pkill -9 -f '^/opt/liongard/' 2>/dev/null || true
    fi

    # Remove stale, Liongard-specific systemd unit files.
    local svc_file
    for svc_file in /etc/systemd/system/roaragent.service \
                    /etc/systemd/system/liongard-agent.service \
                    /lib/systemd/system/roaragent.service \
                    /lib/systemd/system/liongard-agent.service \
                    /usr/lib/systemd/system/roaragent.service \
                    /usr/lib/systemd/system/liongard-agent.service; do
        if [[ -f "${svc_file}" ]]; then
            log_info "Removing stale service unit: ${svc_file}"
            rm -f "${svc_file}" 2>/dev/null || log_warn "Could not remove ${svc_file}."
        fi
    done

    # Disable and stop the Liongard auto-updater timer before reloading systemd.
    # Without this the timer fires in the background and re-installs a newer agent
    # version, causing the installer to find an orphaned config and refuse to install.
    if _has_cmd systemctl; then
        local timer_name
        for timer_name in liongard-agent-updater liongard-updater roaragent-updater; do
            systemctl stop    "${timer_name}.timer" 2>/dev/null || true
            systemctl disable "${timer_name}.timer" 2>/dev/null || true
        done
        # The timer runs liongard-agent-updater.service; stop it in case an update is running.
        systemctl stop    liongard-agent-updater.service 2>/dev/null || true
        systemctl disable liongard-agent-updater.service 2>/dev/null || true
        local timer_file
        for timer_file in \
            /etc/systemd/system/liongard-agent-updater.timer \
            /etc/systemd/system/liongard-agent-updater.service \
            /etc/systemd/system/liongard-updater.timer \
            /lib/systemd/system/liongard-agent-updater.timer \
            /lib/systemd/system/liongard-agent-updater.service \
            /lib/systemd/system/liongard-updater.timer \
            /usr/lib/systemd/system/liongard-agent-updater.timer \
            /usr/lib/systemd/system/liongard-agent-updater.service \
            /usr/lib/systemd/system/liongard-updater.timer; do
            if [[ -f "${timer_file}" || -L "${timer_file}" ]]; then
                log_info "Removing updater unit: ${timer_file}"
                rm -f "${timer_file}" 2>/dev/null || true
            fi
        done
    fi

    _has_cmd systemctl && systemctl daemon-reload 2>/dev/null || true

    # Clear any lingering systemd failed-state entries so list-units no longer
    # shows the removed service. This matters for the post-uninstall detection check.
    if _has_cmd systemctl; then
        local svc
        for svc in "${SERVICE_NAMES[@]}"; do
            systemctl reset-failed "${svc}" 2>/dev/null || true
            systemctl reset-failed "${svc}.timer" 2>/dev/null || true
        done
    fi

    # Run the agent's own uninstall script when present.
    # .run / self-extracting installers often ship one alongside the binary.
    local uninstall_script
    for uninstall_script in \
        /opt/liongard/uninstall.sh      /opt/liongard/uninstall \
        /opt/liongard-agent/uninstall.sh /opt/liongard-agent/uninstall \
        /usr/local/liongard/uninstall.sh /usr/local/liongard/uninstall; do
        if [[ -x "${uninstall_script}" ]]; then
            log_info "Running agent uninstall script: ${uninstall_script}"
            "${uninstall_script}" 2>/dev/null || true
        fi
    done

    # Remove agent binaries from standard PATH locations.
    local bin_path
    for bin_path in \
        /usr/local/bin/liongard-agent /usr/bin/liongard-agent \
        /usr/local/bin/roaragent      /usr/bin/roaragent \
        /usr/local/bin/liongardagent  /usr/bin/liongardagent; do
        if [[ -f "${bin_path}" ]]; then
            log_info "Removing agent binary: ${bin_path}"
            rm -f "${bin_path}" 2>/dev/null || log_warn "Could not remove ${bin_path}."
        fi
    done

    # Remove installation directories left by .run / self-extracting installers.
    # /var/log/liongard is intentionally excluded to preserve diagnostic logs.
    local install_dir
    for install_dir in \
        /opt/liongard /opt/liongard-agent \
        /usr/local/liongard /etc/liongard; do
        if [[ -d "${install_dir}" ]]; then
            log_info "Removing agent installation directory: ${install_dir}"
            rm -rf "${install_dir}" 2>/dev/null || log_warn "Could not remove ${install_dir}."
        fi
    done

    log_ok "Stale cleanup steps completed."
}

# ============================================================
# INSTALLER DOWNLOAD
# ============================================================

download_installer() {
    # Creates a private working directory (mktemp -d: owned by root, mode
    # 0700, removed on exit by _cleanup), downloads the installer with retry
    # logic and size validation.
    # Result is written to the global _INSTALLER_PATH — NOT stdout — so that
    # callers do not accidentally capture log lines when using $(...).
    local url="${INSTALLER_URL}"
    local dest_dir
    local dest_file

    if [[ -z "${_WORK_DIR}" ]]; then
        _WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/liongard-agent.XXXXXXXX" 2>/dev/null)" || {
            _WORK_DIR=""
            log_error "Cannot create a private download directory under [${TMPDIR:-/tmp}]."
            exit 5
        }
    fi
    dest_dir="${_WORK_DIR}"

    if [[ -n "${INSTALLER_FILE_NAME}" ]]; then
        dest_file="${dest_dir}/${INSTALLER_FILE_NAME}"
    else
        dest_file="${dest_dir}/${url##*/}"
        # Strip query strings from the filename if present.
        dest_file="${dest_file%%\?*}"
    fi

    log_step "Downloading Liongard Agent installer..."
    log_info "URL         : ${url}"
    log_info "Destination : ${dest_file}"

    local attempt=0
    while [[ "${attempt}" -lt "${MAX_DOWNLOAD_ATTEMPTS}" ]]; do
        (( ++attempt ))
        log_info "Download attempt ${attempt}/${MAX_DOWNLOAD_ATTEMPTS}..."

        [[ -f "${dest_file}" ]] && rm -f "${dest_file}"

        local dl_ok=true
        if [[ "${_HTTP_CLIENT}" == "curl" ]]; then
            curl -sSL --fail -o "${dest_file}" "${url}" 2>/dev/null || dl_ok=false
        else
            wget -qO "${dest_file}" "${url}" 2>/dev/null || dl_ok=false
        fi

        if [[ "${dl_ok}" == false || ! -f "${dest_file}" ]]; then
            log_warn "Attempt ${attempt} failed to produce a file."
            continue
        fi

        local size
        size="$(wc -c < "${dest_file}" 2>/dev/null || printf '0')"
        if [[ "${size}" -lt "${MINIMUM_INSTALLER_BYTES}" ]]; then
            log_warn "Downloaded file is ${size} bytes (minimum: ${MINIMUM_INSTALLER_BYTES}). Retrying..."
            continue
        fi

        log_ok "Installer downloaded and verified (${size} bytes): ${dest_file}"
        _INSTALLER_PATH="${dest_file}"
        return 0
    done

    log_error "Installer download failed after ${MAX_DOWNLOAD_ATTEMPTS} attempts."
    exit 5
}

# ============================================================
# INSTALL
# ============================================================

# Run a command, log each output line, capture the exit code.
# Usage: _run_logged <log_prefix> <command> [args...]
_run_logged() {
    local prefix="$1"; shift
    local tmp exit_code=0
    tmp="$(mktemp)"

    "$@" >"${tmp}" 2>&1 || exit_code=$?

    while IFS= read -r line; do
        log_info "${prefix}: ${line}"
    done < "${tmp}"
    rm -f "${tmp}"

    return "${exit_code}"
}

run_installer() {
    local pkg_file="$1"
    local local_hostname="$2"

    log_step "Installing Liongard Agent from [${pkg_file}]..."

    # Build an associative array of installer parameters.
    declare -A _install_env
    _install_env["${PARAM_URL}"]="${_INSTANCE_HOST}"
    _install_env["${PARAM_ACCESS_KEY}"]="${AGENT_TOKEN_KEY}"
    _install_env["${PARAM_ACCESS_SECRET}"]="${AGENT_TOKEN_SECRET}"
    _install_env["${PARAM_AGENT_NAME}"]="${local_hostname}"

    if [[ "${INCLUDE_ENVIRONMENT_VALUE}" == true && -n "${_RESOLVED_ENVIRONMENT}" ]]; then
        _install_env["${PARAM_ENVIRONMENT}"]="${_RESOLVED_ENVIRONMENT}"
    fi
    if [[ -n "${AGENT_DESCRIPTION}" ]]; then
        _install_env["${PARAM_DESCRIPTION}"]="${AGENT_DESCRIPTION}"
    fi
    if [[ -n "${_DEVICE_GUID_OVERRIDE}" ]]; then
        _install_env["${DEVICE_ID_OVERRIDE_ARG_NAME}"]="${_DEVICE_GUID_OVERRIDE}"
    fi

    # The .run (sh) installer takes command-line flags, not env vars, and prints
    # its own sanitised flag list below. For the deb/rpm paths we export these as
    # environment variables (some postinstall scripts read them) and show them here.
    if [[ "${_PKG_TYPE}" != "sh" ]]; then
        log_info "Installer parameters (sanitised):"
        local k display_val
        for k in "${!_install_env[@]}"; do
            display_val="${_install_env[${k}]}"
            case "${k}" in
                "${PARAM_ACCESS_KEY}"|"${PARAM_ACCESS_SECRET}")
                    display_val="$(mask_secret "${display_val}")" ;;
            esac
            log_info "  ${k}=${display_val}"
        done

        for k in "${!_install_env[@]}"; do
            export "${k}=${_install_env[${k}]}"
        done
    fi

    local install_exit=0

    case "${_PKG_TYPE}" in
        deb)
            log_info "Installing .deb package..."
            _run_logged "dpkg" dpkg -i "${pkg_file}" || install_exit=$?

            # Resolve broken dependencies if dpkg failed.
            if [[ "${install_exit}" -ne 0 && "${_PKG_MANAGER}" == "apt" ]]; then
                log_warn "dpkg returned ${install_exit}; running apt-get install -f to resolve dependencies..."
                _run_logged "apt-get" apt-get install -f -y || install_exit=$?
            fi
            ;;
        rpm)
            if   _has_cmd dnf;    then _run_logged "dnf"    dnf    install -y "${pkg_file}" || install_exit=$?
            elif _has_cmd yum;    then _run_logged "yum"    yum    localinstall -y "${pkg_file}" || install_exit=$?
            elif _has_cmd zypper; then _run_logged "zypper" zypper --non-interactive install "${pkg_file}" || install_exit=$?
            elif _has_cmd rpm;    then _run_logged "rpm"    rpm    -Uvh "${pkg_file}" || install_exit=$?
            else
                log_error "No RPM-capable package manager found."
                exit 6
            fi
            ;;
        sh)
            chmod +x "${pkg_file}" || true

            # The Liongard .run (makeself) installer does NOT read environment
            # variables. It requires command-line flags passed AFTER a literal
            # '--' separator (everything before '--' goes to the makeself wrapper,
            # everything after goes to the bundled startup.sh). Flags (getopts
            # 'u:k:s:n:e:d:p:g:x' in startup.sh, verified on agent v5.4.1):
            #   -u URL  -k ACCESS_KEY  -s ACCESS_SECRET  -n NAME  -e ENVIRONMENT
            #   -d DESCRIPTION  -p PROXY  -g DEVICE_GUID (override)  -x (uninstall)
            # The -g flag maps to startup.sh's deviceGuid and overrides the
            # machine-id the agent would otherwise self-report. It was added in
            # 5.4.x; the 5.3.1 LTS build silently ignores unknown flags, so a
            # generated override only takes effect on 5.4.0+ installers.
            local -a _sh_args=( -- )
            _sh_args+=( -u "${_INSTANCE_HOST}" )
            _sh_args+=( -k "${AGENT_TOKEN_KEY}" )
            _sh_args+=( -s "${AGENT_TOKEN_SECRET}" )
            _sh_args+=( -n "${local_hostname}" )
            if [[ "${INCLUDE_ENVIRONMENT_VALUE}" == true && -n "${_RESOLVED_ENVIRONMENT}" ]]; then
                _sh_args+=( -e "${_RESOLVED_ENVIRONMENT}" )
            fi
            if [[ -n "${AGENT_DESCRIPTION}" ]]; then
                _sh_args+=( -d "${AGENT_DESCRIPTION}" )
            fi
            if [[ -n "${_DEVICE_GUID_OVERRIDE}" ]]; then
                _sh_args+=( -g "${_DEVICE_GUID_OVERRIDE}" )
                log_info "Applying DEVICEID override via -g: ${_DEVICE_GUID_OVERRIDE}"
                log_info "(Requires agent installer v5.4.0+; older builds ignore -g.)"
            fi

            # Sanitised flag list (mask the access key and secret values).
            log_info "Installer flags (sanitised):"
            local i flag val
            for (( i = 1; i < ${#_sh_args[@]}; i += 2 )); do
                flag="${_sh_args[i]}"
                val="${_sh_args[i+1]}"
                case "${flag}" in
                    -k|-s) val="$(mask_secret "${val}")" ;;
                esac
                log_info "  ${flag} ${val}"
            done

            # --nox11 is a makeself option, so it goes before the '--' that starts
            # _sh_args. Without it, a DISPLAY with no tty (sudo from a desktop
            # session) makes the wrapper re-run itself in xterm: multi-word values
            # are split and the exit code is xterm's, not the installer's.
            log_info "Running shell installer with --nox11 and command-line flags..."
            _run_logged "installer" "${pkg_file}" --nox11 "${_sh_args[@]}" || install_exit=$?
            ;;
        *)
            log_error "Unsupported package type: ${_PKG_TYPE}"
            exit 6
            ;;
    esac

    # Unset exported parameters.
    for k in "${!_install_env[@]}"; do
        unset "${k}"
    done
    unset _install_env

    if [[ "${install_exit}" -ne 0 ]]; then
        log_error "Installer exited with code ${install_exit}."
        return "${install_exit}"
    fi

    log_ok "Installer completed successfully."
    return 0
}

# ============================================================
# INSTALLATION VALIDATION
# ============================================================

validate_installation() {
    log_step "Validating Liongard Agent installation..."

    local svc_found=false svc_running=false detected_svc="" pkg_found=false
    local svc

    # Service existence and status.
    for svc in "${SERVICE_NAMES[@]}"; do
        local found_this=false

        if _has_cmd systemctl; then
            if systemctl list-units --all --type=service 2>/dev/null | grep -q "${svc}"; then
                found_this=true
            fi
        fi
        if [[ "${found_this}" == false ]] && _has_cmd service; then
            service "${svc}" status &>/dev/null && found_this=true || true
        fi

        if [[ "${found_this}" == true ]]; then
            svc_found=true
            detected_svc="${svc}"
            if _has_cmd systemctl && systemctl is-active --quiet "${svc}" 2>/dev/null; then
                svc_running=true
            fi
            break
        fi
    done

    # Attempt one service start if found but not yet running.
    if [[ "${svc_found}" == true && "${svc_running}" == false ]]; then
        log_warn "Service '${detected_svc}' exists but is not running. Attempting to start..."
        if _has_cmd systemctl; then
            systemctl start "${detected_svc}" 2>/dev/null || true
        elif _has_cmd service; then
            service "${detected_svc}" start 2>/dev/null || true
        fi
        sleep 3
        if _has_cmd systemctl && systemctl is-active --quiet "${detected_svc}" 2>/dev/null; then
            svc_running=true
        fi
    fi

    # Package installation check.
    if _has_cmd dpkg && dpkg -l 2>/dev/null | grep -qi liongard; then pkg_found=true; fi
    if [[ "${pkg_found}" == false ]] && _has_cmd rpm && rpm -qa 2>/dev/null | grep -qi liongard; then pkg_found=true; fi

    # Scrape recent log lines for useful signals.
    local log_snippet=""
    local log_dir
    for log_dir in /var/log/liongard /opt/liongard/logs /usr/local/liongard/logs; do
        if [[ -d "${log_dir}" ]]; then
            log_snippet="$(find "${log_dir}" -type f -name '*.log' 2>/dev/null \
                | head -1 \
                | xargs grep -i -E 'error|warn|fail|success|register|heartbeat' 2>/dev/null \
                | tail -5)" || true
            break
        fi
    done
    if [[ -z "${log_snippet}" && -n "${detected_svc}" ]] && _has_cmd journalctl; then
        log_snippet="$(journalctl -u "${detected_svc}" --no-pager -n 20 2>/dev/null \
            | grep -i -E 'error|warn|fail|success|register|heartbeat' \
            | tail -5)" || true
    fi

    # Summary report.
    log_step "=== Installation Validation Summary ==="
    log_info "Service found     : ${svc_found}"
    log_info "Service running   : ${svc_running}"
    log_info "Detected service  : ${detected_svc:-none}"
    log_info "Package installed : ${pkg_found}"
    if [[ -n "${log_snippet}" ]]; then
        log_info "Recent log lines  :"
        while IFS= read -r line; do
            log_info "  ${line}"
        done <<< "${log_snippet}"
    fi
    log_step "======================================="

    if [[ "${svc_running}" == true || "${pkg_found}" == true ]]; then
        log_ok "Liongard Agent installation validated successfully."
        return 0
    fi

    log_warn "Liongard Agent installation could not be fully validated."
    return 7
}

# ============================================================
# MAIN EXECUTION
# ============================================================

main() {
    start_transcript

    log_step "============================================================"
    log_step " Liongard Agent Linux Deployment Script"
    log_step " $(date '+%Y-%m-%d %H:%M:%S %Z')"
    log_step "============================================================"

    # ── Step 1: Sanity checks ──────────────────────────────────────────
    check_root
    validate_config
    resolve_instance_prefix
    resolve_installer_url
    check_prerequisites
    print_config_snapshot

    # ── Step 2: Detect distro ──────────────────────────────────────────
    detect_distro

    # ── Step 3: Build API auth header ──────────────────────────────────
    build_auth_header

    # ── Step 4: Collect local identity signals ─────────────────────────
    local local_hostname
    local_hostname="$(hostname 2>/dev/null)"
    log_info "Local hostname: ${local_hostname}"

    local local_machine_id
    local_machine_id="$(get_local_machine_id)"
    log_info "Local machine ID: ${local_machine_id}"

    local -a local_hostnames
    mapfile -t local_hostnames < <(get_local_hostnames)
    log_info "Local host identifiers: $(IFS=', '; printf '%s' "${local_hostnames[*]}")"

    # ── Step 5: Existing install (Healthy / Stale / NotInstalled) ──────
    # Read-only. A healthy agent is never removed: it's upgraded in place only
    # when both versions are readable and the installer is strictly newer.
    # Otherwise the agent's own updater timer keeps it current and the script
    # changes nothing. A stale install is removed in step 8, after the checks
    # that can stop the run.
    local upgrade_in_place=false

    get_install_state

    # The token is checked before anything changes on this machine. A stale
    # or missing agent stops here (exit 4) on a failure; a healthy agent is
    # only upgraded or left alone, neither of which needs the API.
    if [[ "${_INSTALL_STATE}" == "Healthy" ]]; then
        check_api_access warn
    else
        check_api_access
    fi

    if [[ "${_INSTALL_STATE}" == "Healthy" ]]; then
        local installed_version="" installer_version=""
        installed_version="$(get_installed_agent_version)" || installed_version=""
        if [[ -z "${installed_version}" ]]; then
            log_info "A healthy Liongard Agent is installed, but its version can't be read from ${AGENT_CONFIG_PATH}. No changes made; the agent's updater keeps it current. Exiting (success)."
            exit 0
        fi
        download_installer
        installer_version="$(get_installer_agent_version "${_INSTALLER_PATH}")" || installer_version=""
        if [[ -z "${installer_version}" ]]; then
            log_info "A healthy Liongard Agent ${installed_version} is installed, but the installer's version can't be read. No changes made; the agent's updater keeps it current. Exiting (success)."
            exit 0
        fi
        log_info "Installed agent version: ${installed_version} | Installer version: ${installer_version}"
        if ! _version_gt "${installer_version}" "${installed_version}"; then
            log_info "Liongard Agent ${installed_version} is already installed and the installer (${installer_version}) is not newer. No changes made. Exiting (success)."
            exit 0
        fi
        log_info "Newer version available. Upgrading in place: ${installed_version} -> ${installer_version}. The agent keeps its registration and identity."
        upgrade_in_place=true
    fi

    # ── Step 6: Environment name resolution ────────────────────────────
    # Runs before any removal, so an ambiguous name or a failed API call stops
    # the run with nothing changed. An environment that does not exist is left
    # out (the install fails otherwise), or created when
    # CREATE_ENVIRONMENT_IF_MISSING=true. An in-place upgrade keeps the
    # existing registration (the installer skips registration when the agent
    # config exists), so steps 6, 7 and 10 don't apply to it.
    if [[ "${upgrade_in_place}" == true ]]; then
        log_info "Upgrading in place: environment matching and the collision check are skipped (the existing registration is kept)."
    elif [[ "${INCLUDE_ENVIRONMENT_VALUE}" == true ]]; then
        if [[ "${ENABLE_ENVIRONMENT_MATCHING}" == true ]]; then
            local resolve_rc=0 env_norm
            env_norm="$(normalize_env_name "${ENVIRONMENT}")"
            if [[ "${CREATE_ENVIRONMENT_IF_MISSING}" == true ]]; then
                resolve_environment_name exact-only || resolve_rc=$?
            else
                resolve_environment_name || resolve_rc=$?
            fi
            case "${resolve_rc}" in
                0) ;;
                2)
                    log_error "Environment '${ENVIRONMENT}' (normalized '${env_norm}') matches more than one Liongard environment. Set ENVIRONMENT to the exact name. Aborting."
                    exit 4
                    ;;
                3)
                    log_error "Environment '${ENVIRONMENT}' could not be checked because the Liongard API call failed. Aborting."
                    exit 4
                    ;;
                *)
                    if [[ "${CREATE_ENVIRONMENT_IF_MISSING}" != true ]] || ! create_environment; then
                        local not_created=""
                        if [[ "${CREATE_ENVIRONMENT_IF_MISSING}" == true ]]; then
                            not_created=" and could not be created"
                        fi
                        _RESOLVED_ENVIRONMENT=""
                        _ENVIRONMENT_WARNING="Environment '${ENVIRONMENT}' was not found in Liongard${not_created}. The agent was installed without an environment; assign it in Liongard."
                        log_warn "Environment '${ENVIRONMENT}' was not found in Liongard${not_created}. The agent will be installed without an environment; assign it in Liongard."
                    fi
                    ;;
            esac
        else
            if [[ "${CREATE_ENVIRONMENT_IF_MISSING}" == true ]]; then
                log_warn "CREATE_ENVIRONMENT_IF_MISSING=true is ignored because ENABLE_ENVIRONMENT_MATCHING=false."
            fi
            _RESOLVED_ENVIRONMENT="${ENVIRONMENT}"
            log_info "Environment matching disabled; using value verbatim: ${_RESOLVED_ENVIRONMENT}"
        fi
        if [[ -n "${_RESOLVED_ENVIRONMENT}" ]]; then
            log_ok "Resolved environment: ${_RESOLVED_ENVIRONMENT}"
        fi
    fi

    # ── Step 7: Liongard agent API query for collision detection ───────
    local escaped_machine_id="${local_machine_id//\'/\'\'}"
    local machine_id_condition="MachineGuid = '${escaped_machine_id}'"
    local agents_json="[]"
    local api_ok=true

    if [[ "${upgrade_in_place}" == true ]]; then
        api_ok=false
    elif ! agents_json="$(get_agents_filtered "${machine_id_condition}")"; then
        api_ok=false
        log_warn "Liongard agent API lookup failed."
        if [[ "${API_FAILURE_BEHAVIOR}" == "conservative" ]]; then
            log_error "API_FAILURE_BEHAVIOR=conservative. Cannot continue without collision detection. Aborting."
            exit 4
        else
            log_warn "API_FAILURE_BEHAVIOR=permissive. Continuing without DEVICEID override."
        fi
    fi

    # ── Step 8: Stale cleanup ──────────────────────────────────────────
    # Leftovers are removed so the installer can't pick up an old config.
    # Platform record deletion only follows a removed local agent.
    local do_remote_deletion=false
    case "${_INSTALL_STATE}" in
        Stale)
            local had_agent=false
            is_agent_installed && had_agent=true
            invoke_liongard_agent_uninstall

            if is_agent_installed; then
                log_error "Liongard Agent is still detected after stale cleanup. Aborting."
                exit 8
            fi
            local -a remaining=()
            mapfile -t remaining < <(_find_install_leftovers)
            if [[ "${#remaining[@]}" -gt 0 ]]; then
                log_warn "Stale cleanup left: $(IFS=', '; printf '%s' "${remaining[*]}"). Continuing with a fresh install."
            fi
            log_ok "Stale Liongard Agent install removed."
            if [[ "${had_agent}" == true && "${REMOVE_AGENT_FROM_PLATFORM}" == true ]]; then
                do_remote_deletion=true
            fi
            log_info "Proceeding with fresh install..."
            ;;
        NotInstalled)
            log_info "No Liongard Agent installation detected. Proceeding with fresh install..."
            ;;
    esac

    if [[ "${REMOVE_AGENT_FROM_PLATFORM}" == true && "${do_remote_deletion}" == false ]]; then
        log_info "REMOVE_AGENT_FROM_PLATFORM=true is ignored: no local agent was removed in this run."
    fi

    # ── Step 9: Optional remote platform agent deletion ────────────────
    # Matches by environment and exact hostname only (see invoke_remote_agent_removal).
    if [[ "${do_remote_deletion}" == true ]]; then
        log_step "Attempting remote platform agent deletion..."
        local -a deletion_hostnames=()
        mapfile -t deletion_hostnames < <(get_deletion_hostnames)
        invoke_remote_agent_removal "${deletion_hostnames[@]}"
    fi

    # ── Step 10: Collision detection → DEVICEID override ───────────────
    if [[ "${api_ok}" == true ]]; then
        resolve_device_guid_override "${local_machine_id}" "${agents_json}" "${local_hostnames[@]}"
    fi

    # Log the collision-detection decision.
    if [[ -n "${_DEVICE_GUID_OVERRIDE}" ]]; then
        log_info "DEVICEID override will be passed to installer: ${_DEVICE_GUID_OVERRIDE}"
    else
        log_info "No DEVICEID override required."
    fi

    # ── Step 11: Download installer ────────────────────────────────────
    # download_installer writes to _INSTALLER_PATH (not stdout) to avoid
    # log-line pollution when captured via $(...). A Healthy install already
    # downloaded it to read the installer version.
    if [[ -z "${_INSTALLER_PATH}" ]]; then
        download_installer
    fi
    local installer_path="${_INSTALLER_PATH}"

    # ── Step 12: Install ───────────────────────────────────────────────
    # Use || to capture the real exit code — avoid `if ! cmd` which inverts
    # $? through the logical-NOT operator, making it always 0 in the body.
    local install_exit=0
    run_installer "${installer_path}" "${local_hostname}" || install_exit=$?
    if [[ "${install_exit}" -ne 0 ]]; then
        log_error "Installation failed (exit code ${install_exit})."
        exit 6
    fi

    # Short pause to allow the service to initialise before validation.
    sleep 3

    # ── Step 13: Validate ──────────────────────────────────────────────
    local validate_exit=0
    validate_installation || validate_exit=$?
    if [[ "${validate_exit}" -ne 0 ]]; then
        log_warn "Post-install validation returned code ${validate_exit}."
        exit 7
    fi

    log_step "============================================================"
    log_ok   " Liongard Agent deployment complete."
    if [[ -n "${_ENVIRONMENT_WARNING}" ]]; then
        log_warn " ${_ENVIRONMENT_WARNING}"
    fi
    log_step "============================================================"
    exit 0
}

main "$@"
