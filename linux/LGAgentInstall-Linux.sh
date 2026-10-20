#!/usr/bin/env bash
#
# ============================================================
# Liongard Agent – Linux Deployment Script
# ============================================================

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
INSTANCE_PREFIX="us?"                                  # e.g. us1, us2, eu1

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
ENABLE_ENVIRONMENT_MATCHING=true

# Remove any existing Liongard Agent on this machine before installing.
ENABLE_PRE_UNINSTALL=true

# After a successful pre-uninstall, also delete the matching agent record from
# the Liongard platform via the API. Only applies when ENABLE_PRE_UNINSTALL=true.
REMOVE_AGENT_FROM_PLATFORM=false

# Optional free-text description for the agent. Passed only when non-empty.
AGENT_DESCRIPTION=""

# Directory for the log transcript. Created root-only (0700) when missing.
LOG_DIRECTORY="/var/log/liongard-agent"

# DEPRECATED: no longer used and will be removed in a later release. The
# installer now downloads to a private temporary directory that is removed on
# exit, and the log transcript goes to LOG_DIRECTORY. A WARN is logged if set.
DOWNLOAD_DIRECTORY=""

# Installer download URL. Package type is inferred from the file extension
# (.deb / .rpm / .sh / .run). NOTE: the MachineGuid collision override (passed
# to the installer via -g) requires an agent installer v5.4.0 or newer; older
# builds silently ignore it.
INSTALLER_URL="https://agents.static.liongard.com/LiongardAgent-lts-x64.xz.run"

# Saved installer filename. Leave empty to infer it from the URL.
INSTALLER_FILE_NAME=""

# ------------------------------------------------------------
# C. ADVANCED OPTIONS — normally leave unchanged
# Advanced options below should normally remain unchanged unless directed
# by Liongard Support.
# ------------------------------------------------------------

# Minimum confidence score (0–185) required before deleting a remote record.
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
# USAGE
#   sudo bash LGAgentInstall-Linux.sh
#
# DESCRIPTION
#   Linux-native equivalent of the Liongard Windows PowerShell
#   agent deployment script. High-level workflow:
#     1.  Validate partner configuration.
#     2.  Check prerequisites and detect the Linux distribution.
#     3.  Optionally remove any existing Liongard Agent.
#     4.  Optionally delete the matching platform record via API.
#     5.  Resolve the environment name against the Liongard API.
#     6.  Query the Liongard API for machine-ID collisions and
#         generate a DEVICEID override when needed.
#     7.  Download and install the appropriate package (deb/rpm/sh).
#     8.  Validate the installation and report results.
#
# PREREQUISITES
#   - Must run as root (or via sudo).
#   - curl or wget must be present.
#   - jq is required when EnableEnvironmentMatching=true or
#     RemoveAgentFromPlatform=true.
#   - Tested targets: Ubuntu 20.04+, Debian 10+, RHEL/Rocky/Alma 8+,
#     CentOS 7+, Amazon Linux 2, SUSE 15+, Fedora 36+.
#   - Requires Bash 4.0+ (all targets above ship with 4.2+).
#
# EXIT CODES
#   0  – Success (installed, or agent already present + pre-uninstall off)
#   1  – Generic / unexpected failure
#   2  – Missing or invalid required configuration
#   3  – Missing prerequisites
#   4  – API or environment resolution failure
#   5  – Installer download failed
#   6  – Install command failed
#   7  – Install completed but post-install validation failed
#   8  – Pre-uninstall failed or agent still detected afterward
#
# Liongard Partner Support
# ============================================================

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
_HTTP_CLIENT=""         # curl | wget
_INSTALLER_PATH=""      # set by download_installer; avoids stdout-capture pollution
_WORK_DIR=""            # private mktemp -d directory; removed on exit
_WGET_CONFIG_FILE=""    # 0600 wgetrc holding the auth header; removed on exit

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
    log_info "EnablePreUninstall          : ${ENABLE_PRE_UNINSTALL}"
    log_info "RemoveAgentFromPlatform     : ${REMOVE_AGENT_FROM_PLATFORM}"
    log_info "MinimumRemoteDeletionScore  : ${MINIMUM_REMOTE_DELETION_SCORE}"
    log_info "LogDirectory                : ${LOG_DIRECTORY}"
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
    log_ok "Configuration validated."
}

# ============================================================
# INSTANCE PREFIX NORMALIZATION
# Accepts: us1 | us1.app.liongard.com | https://us1.app.liongard.com
# Sets:    _INSTANCE_HOST, _INSTANCE_BASE_URL
# ============================================================

resolve_instance_prefix() {
    local raw="${INSTANCE_PREFIX}"
    local sanitized

    # Strip URL scheme if present.
    sanitized="${raw#https://}"
    sanitized="${sanitized#http://}"
    # Strip trailing slashes.
    sanitized="${sanitized%/}"

    # If it looks like a full hostname, extract only the first label.
    if [[ "${sanitized}" == *".app.liongard.com" ]]; then
        sanitized="${sanitized%%.*}"
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

    # MAC collection utilities — warn only, script continues.
    if ! _has_cmd ip && ! _has_cmd ifconfig; then
        log_warn "Neither 'ip' nor 'ifconfig' found; MAC address collection will use /sys/class/net only."
    fi

    # jq is required when environment matching or scored remote deletion is on.
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
# MAC ADDRESS COLLECTION
# ============================================================

_normalize_mac() {
    local raw="$1"
    local clean
    # Keep only hex-digit characters, stripping all separators.
    # Avoid tr ranges that cross ASCII order (e.g. ':- ' → descending range error).
    clean="$(printf '%s' "${raw}" | tr -cd '0-9a-fA-F')"
    if [[ "${#clean}" -lt 12 ]]; then
        return 1
    fi
    printf '%s' "${clean:0:12}" | tr '[:lower:]' '[:upper:]'
}

get_local_mac_addresses() {
    # Returns normalized (no-separator, uppercase) MAC addresses for all
    # active non-loopback interfaces, one per line, deduplicated.
    local -A mac_set=()
    local mac

    # ip link show (preferred).
    if _has_cmd ip; then
        while IFS= read -r line; do
            if [[ "${line}" =~ link/ether[[:space:]]([0-9a-fA-F:]{17}) ]]; then
                mac="$(_normalize_mac "${BASH_REMATCH[1]}")" && mac_set["${mac}"]=1 || true
            fi
        done < <(ip link show 2>/dev/null | grep -v 'link/loopback')
    fi

    # ifconfig fallback.
    if [[ "${#mac_set[@]}" -eq 0 ]] && _has_cmd ifconfig; then
        while IFS= read -r line; do
            if [[ "${line}" =~ ([Hh][Ww][Aa][Dd][Dd][Rr]|ether)[[:space:]]+([0-9a-fA-F:]{17}) ]]; then
                mac="$(_normalize_mac "${BASH_REMATCH[2]}")" && mac_set["${mac}"]=1 || true
            fi
        done < <(ifconfig 2>/dev/null)
    fi

    # /sys/class/net/*/address last resort.
    if [[ "${#mac_set[@]}" -eq 0 ]]; then
        local iface addr_file
        for addr_file in /sys/class/net/*/address; do
            iface="${addr_file%/address}"; iface="${iface##*/}"
            [[ "${iface}" == lo ]] && continue
            local raw_mac
            raw_mac="$(cat "${addr_file}" 2>/dev/null)"
            [[ -z "${raw_mac}" || "${raw_mac}" == "00:00:00:00:00:00" ]] && continue
            mac="$(_normalize_mac "${raw_mac}")" && mac_set["${mac}"]=1 || true
        done
    fi

    [[ "${#mac_set[@]}" -gt 0 ]] && printf '%s\n' "${!mac_set[@]}"
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
# On success: sets _RESOLVED_ENVIRONMENT and returns 0.
# On failure: logs a warning and returns 1.
resolve_environment_name() {
    local input_name="${ENVIRONMENT}"
    local input_norm
    input_norm="$(normalize_env_name "${input_name}")"

    if [[ "${#input_norm}" -lt 4 ]]; then
        log_warn "Environment '${input_name}' normalizes to '${input_norm}' — too short for reliable matching (min 4 chars)."
        return 1
    fi

    log_step "Resolving environment '${input_name}' against Liongard API..."

    local response
    if ! response="$(_api_get "/environments" 2>/dev/null)"; then
        log_warn "Could not retrieve Liongard environments from API."
        return 1
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
        log_warn "No environment names extracted from API response."
        return 1
    fi

    local -a env_names=()
    while IFS= read -r line; do
        [[ -n "${line}" ]] && env_names+=("${line}")
    done <<< "${names_raw}"

    local input_lower
    input_lower="$(printf '%s' "${input_name}" | tr '[:upper:]' '[:lower:]')"

    # 1. Exact case-insensitive match.
    local name name_lower
    for name in "${env_names[@]}"; do
        name_lower="$(printf '%s' "${name}" | tr '[:upper:]' '[:lower:]')"
        if [[ "${name_lower}" == "${input_lower}" ]]; then
            log_info "Environment exact match: '${input_name}' → '${name}'"
            _RESOLVED_ENVIRONMENT="${name}"; return 0
        fi
    done

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
        return 1
    fi

    # 3. Single prefix match.
    if [[ "${#prefix_matches[@]}" -eq 1 ]]; then
        log_info "Environment prefix match: '${input_name}' → '${prefix_matches[0]}'"
        _RESOLVED_ENVIRONMENT="${prefix_matches[0]}"; return 0
    elif [[ "${#prefix_matches[@]}" -gt 1 ]]; then
        log_warn "Ambiguous prefix environment match for '${input_name}'. Candidates: ${prefix_matches[*]}"
        return 1
    fi

    # 4. Single contains match.
    if [[ "${#contains_matches[@]}" -eq 1 ]]; then
        log_info "Environment contains match: '${input_name}' → '${contains_matches[0]}'"
        _RESOLVED_ENVIRONMENT="${contains_matches[0]}"; return 0
    elif [[ "${#contains_matches[@]}" -gt 1 ]]; then
        log_warn "Ambiguous contains environment match for '${input_name}'. Candidates: ${contains_matches[*]}"
        return 1
    fi

    # 5. No match.
    local sample
    sample="$(printf '%s\n' "${env_names[@]:0:5}" | tr '\n' ';' | sed 's/;$//' | sed 's/;/; /g')"
    log_warn "No Liongard environment matched '${input_name}' (normalized '${input_norm}'). Sample known names: ${sample}"
    return 1
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
# ============================================================

# Confidence scoring mirrors the Windows script model:
#   MachineGuid exact match  → +100
#   Hostname match           → +30 (+5 per additional, max +15 bonus)
#   MAC address match        → +40 (+5 per additional, max +10 bonus)
_score_agent() {
    local agent_json="$1"
    local local_machine_id="$2"
    shift 2
    local -a local_hostnames=("$@")

    local score=0

    # MachineGuid match.
    local agent_guid
    agent_guid="$(printf '%s' "${agent_json}" | jq -r '(.MachineGuid // "") | ascii_downcase' 2>/dev/null)"
    if [[ -n "${agent_guid}" && "${agent_guid}" == "${local_machine_id}" ]]; then
        (( score += 100 ))
    fi

    # Hostname match.
    local agent_hostname h h_lower
    agent_hostname="$(printf '%s' "${agent_json}" | jq -r '(.Hostname // .Name // "") | ascii_downcase' 2>/dev/null)"
    local host_hits=0
    for h in "${local_hostnames[@]}"; do
        h_lower="$(printf '%s' "${h}" | tr '[:upper:]' '[:lower:]')"
        if [[ -n "${agent_hostname}" && "${h_lower}" == "${agent_hostname}" ]]; then
            (( ++host_hits ))
        fi
    done
    if [[ "${host_hits}" -gt 0 ]]; then
        local hbonus=$(( 5 * (host_hits - 1) ))
        [[ "${hbonus}" -gt 15 ]] && hbonus=15
        (( score += 30 + hbonus ))
    fi

    # MAC address match.
    local -a local_macs
    mapfile -t local_macs < <(get_local_mac_addresses)
    local agent_macs_raw mac_entry clean_agent_mac lm
    agent_macs_raw="$(printf '%s' "${agent_json}" | jq -r '
        (.MACAddress // .MacAddress // .Data.MACAddress // "") |
        if type == "array" then join(",") else . end
    ' 2>/dev/null)"

    local mac_hits=0
    local OLD_IFS="${IFS}"; IFS=",; "
    for mac_entry in ${agent_macs_raw}; do
        clean_agent_mac="$(_normalize_mac "${mac_entry}")" || continue
        for lm in "${local_macs[@]}"; do
            if [[ "${clean_agent_mac}" == "${lm}" ]]; then
                (( ++mac_hits ))
                break
            fi
        done
    done
    IFS="${OLD_IFS}"

    if [[ "${mac_hits}" -gt 0 ]]; then
        local mbonus=$(( 5 * (mac_hits - 1) ))
        [[ "${mbonus}" -gt 10 ]] && mbonus=10
        (( score += 40 + mbonus ))
    fi

    printf '%d' "${score}"
}

invoke_remote_agent_removal() {
    local agents_json="$1"
    local local_machine_id="$2"
    shift 2
    local -a local_hostnames=("$@")

    if [[ -z "${agents_json}" || "${agents_json}" == "[]" || "${agents_json}" == "null" ]]; then
        log_info "No agents returned; remote deletion skipped."
        return 0
    fi

    if ! _has_cmd jq; then
        log_warn "jq required for remote deletion scoring. Skipping."
        return 0
    fi

    local best_score=0 best_agent_id=""
    local agent_json agent_id score

    while IFS= read -r agent_json; do
        [[ -z "${agent_json}" || "${agent_json}" == "null" ]] && continue
        score="$(_score_agent "${agent_json}" "${local_machine_id}" "${local_hostnames[@]}")"
        agent_id="$(printf '%s' "${agent_json}" | jq -r '.ID // .id // ""' 2>/dev/null)"

        if [[ "${score}" -gt "${best_score}" && -n "${agent_id}" ]]; then
            best_score="${score}"
            best_agent_id="${agent_id}"
        fi
    done < <(printf '%s' "${agents_json}" | jq -c '.[]' 2>/dev/null)

    if [[ -z "${best_agent_id}" ]]; then
        log_info "No Liongard agent record matched the local host identity; remote deletion skipped."
        return 0
    fi

    if [[ "${best_score}" -lt "${MINIMUM_REMOTE_DELETION_SCORE}" ]]; then
        log_warn "Remote deletion skipped: match score ${best_score} is below threshold ${MINIMUM_REMOTE_DELETION_SCORE}."
        return 0
    fi

    log_info "Deleting Liongard agent ID ${best_agent_id} (match score: ${best_score})..."
    local http_status
    http_status="$(_api_delete "/agents/${best_agent_id}")" || { log_warn "DELETE request failed."; return 0; }

    if [[ "${http_status}" == "204" || "${http_status}" == "200" ]]; then
        log_ok "Remote agent ID ${best_agent_id} deleted (HTTP ${http_status})."
    else
        log_warn "Unexpected HTTP ${http_status} while deleting agent ID ${best_agent_id}."
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
        /opt/liongard/liongard-agent  /opt/liongard/bin/liongard-agent \
        /opt/liongard-agent/liongard-agent \
        /usr/local/liongard/liongard-agent; do
        [[ -f "${bin_path}" ]] && return 0
    done

    return 1
}

# ============================================================
# PRE-UNINSTALL
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
    log_step "Pre-uninstall: removing existing Liongard Agent..."

    _stop_liongard_services
    _remove_liongard_package

    # Kill any lingering processes.
    local proc_name
    for proc_name in roaragent liongardagent; do
        if pgrep -x "${proc_name}" &>/dev/null; then
            log_info "Terminating lingering process: ${proc_name}"
            pkill -x "${proc_name}" 2>/dev/null || true
            sleep 1
        fi
    done

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
        local timer_file
        for timer_file in \
            /etc/systemd/system/liongard-agent-updater.timer \
            /etc/systemd/system/liongard-updater.timer \
            /lib/systemd/system/liongard-agent-updater.timer \
            /lib/systemd/system/liongard-updater.timer \
            /usr/lib/systemd/system/liongard-agent-updater.timer \
            /usr/lib/systemd/system/liongard-updater.timer; do
            if [[ -f "${timer_file}" || -L "${timer_file}" ]]; then
                log_info "Removing updater timer unit: ${timer_file}"
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

    log_ok "Pre-uninstall steps completed."
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

            log_info "Running shell installer with command-line flags..."
            _run_logged "installer" "${pkg_file}" "${_sh_args[@]}" || install_exit=$?
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
    check_prerequisites
    print_config_snapshot

    # ── Step 2: Resolve instance and detect distro ─────────────────────
    resolve_instance_prefix
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

    local -a local_macs
    mapfile -t local_macs < <(get_local_mac_addresses)
    log_info "Local MAC addresses: $(IFS=', '; printf '%s' "${local_macs[*]}")"

    # ── Step 5: Pre-uninstall ──────────────────────────────────────────
    local do_remote_deletion=false

    if [[ "${ENABLE_PRE_UNINSTALL}" == true ]]; then
        log_step "Pre-uninstall is enabled..."
        if is_agent_installed; then
            invoke_liongard_agent_uninstall

            if is_agent_installed; then
                log_error "Liongard Agent is still detected after uninstall. Aborting."
                exit 8
            fi
            log_ok "Existing Liongard Agent removed."
            [[ "${REMOVE_AGENT_FROM_PLATFORM}" == true ]] && do_remote_deletion=true
        else
            log_info "No active Liongard Agent service/binary detected."
            log_info "Running full artifact cleanup — orphaned install dirs and config files"
            log_info "can cause the installer to detect a previous agent and refuse to install."
            invoke_liongard_agent_uninstall
        fi
    else
        if is_agent_installed; then
            log_info "Liongard Agent is already installed and EnablePreUninstall=false. Exiting (success)."
            exit 0
        fi
        if [[ "${REMOVE_AGENT_FROM_PLATFORM}" == true ]]; then
            log_warn "RemoveAgentFromPlatform=true is ignored because EnablePreUninstall=false."
        fi
    fi

    log_info "No Liongard Agent installation detected. Proceeding with fresh install..."

    # ── Step 6: Environment name resolution ────────────────────────────
    if [[ "${INCLUDE_ENVIRONMENT_VALUE}" == true ]]; then
        if [[ "${ENABLE_ENVIRONMENT_MATCHING}" == true ]]; then
            if ! resolve_environment_name; then
                local env_norm
                env_norm="$(normalize_env_name "${ENVIRONMENT}")"
                log_error "Environment '${ENVIRONMENT}' (normalized '${env_norm}') could not be resolved in Liongard. Aborting."
                exit 4
            fi
        else
            _RESOLVED_ENVIRONMENT="${ENVIRONMENT}"
            log_info "Environment matching disabled; using value verbatim: ${_RESOLVED_ENVIRONMENT}"
        fi
        log_ok "Resolved environment: ${_RESOLVED_ENVIRONMENT}"
    fi

    # ── Step 7: Liongard agent API query for collision detection ───────
    local escaped_machine_id="${local_machine_id//\'/\'\'}"
    local machine_id_condition="MachineGuid = '${escaped_machine_id}'"
    local agents_json="[]"
    local api_ok=true

    if ! agents_json="$(get_agents_filtered "${machine_id_condition}")"; then
        api_ok=false
        log_warn "Liongard agent API lookup failed."
        if [[ "${API_FAILURE_BEHAVIOR}" == "conservative" ]]; then
            log_error "API_FAILURE_BEHAVIOR=conservative. Cannot continue without collision detection. Aborting."
            exit 4
        else
            log_warn "API_FAILURE_BEHAVIOR=permissive. Continuing without DEVICEID override."
        fi
    fi

    # ── Step 8: Optional remote platform agent deletion ────────────────
    if [[ "${do_remote_deletion}" == true && "${api_ok}" == true ]]; then
        log_step "Attempting remote platform agent deletion..."
        invoke_remote_agent_removal "${agents_json}" "${local_machine_id}" "${local_hostnames[@]}"
    fi

    # ── Step 9: Collision detection → DEVICEID override ────────────────
    if [[ "${api_ok}" == true ]]; then
        resolve_device_guid_override "${local_machine_id}" "${agents_json}" "${local_hostnames[@]}"
    fi

    # Log the collision-detection decision.
    if [[ -n "${_DEVICE_GUID_OVERRIDE}" ]]; then
        log_info "DEVICEID override will be passed to installer: ${_DEVICE_GUID_OVERRIDE}"
    else
        log_info "No DEVICEID override required."
    fi

    # ── Step 10: Download installer ────────────────────────────────────
    # download_installer writes to _INSTALLER_PATH (not stdout) to avoid
    # log-line pollution when captured via $(...).
    download_installer
    local installer_path="${_INSTALLER_PATH}"

    # ── Step 11: Install ───────────────────────────────────────────────
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

    # ── Step 12: Validate ──────────────────────────────────────────────
    local validate_exit=0
    validate_installation || validate_exit=$?
    if [[ "${validate_exit}" -ne 0 ]]; then
        log_warn "Post-install validation returned code ${validate_exit}."
        exit 7
    fi

    log_step "============================================================"
    log_ok   " Liongard Agent deployment complete."
    log_step "============================================================"
    exit 0
}

main "$@"
