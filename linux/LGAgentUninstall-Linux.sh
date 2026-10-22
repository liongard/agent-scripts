#!/usr/bin/env bash
#
# SYNOPSIS
#   Removes the Liongard Agent from a Linux endpoint (local removal only).
#
# DESCRIPTION
#   Uninstalls the Liongard Agent (.run, .sh, .deb or .rpm install) and removes what it leaves
#   behind. There are no settings to fill in. Exit codes and troubleshooting are in the README
#   under LINK.
#   - Stops and removes the agent and updater services and timer, the agent package, processes,
#     binaries and install folders, then reports anything that's left.
#   - Makes no Liongard API calls and keeps the agent's record on the platform. Platform removal
#     isn't included; on Windows, LGAgentUninstall-Advanced.ps1 does it.
#   - Never touches the agent identity (/etc/liongard-agent), so a later reinstall re-attaches
#     to the same platform record. Leaves /etc/liongard in place until the dev team confirms
#     what it holds.
#   - Writes to stdout and stderr only, for your RMM to capture.
#
# NOTES
#   Requires:     root, Bash. No tokens.
#   Author:       Liongard Partner Support
#   Last updated: 2026-10-22
#
# LINK
#   https://github.com/liongard/agent-scripts/blob/main/linux/README.md

# No set -e: every removal step is allowed to fail, and the final check decides the exit code.
set -uo pipefail

# Names and paths from the pre-uninstall of LGAgentInstall-Linux.sh, plus the units the agent
# 5.5.0 installer creates (liongard-agent and liongard-agent-updater, .service and .timer).
SERVICE_NAMES=("roaragent" "liongard-agent" "liongardagent" "LiongardAgent")
UPDATER_NAMES=("liongard-agent-updater" "liongard-updater" "roaragent-updater")
UNIT_DIRS=(/etc/systemd/system /lib/systemd/system /usr/lib/systemd/system)
PROCESS_NAMES=(roaragent liongardagent LiongardAgent)
AGENT_UNINSTALL_SCRIPTS=(
    /opt/liongard/uninstall.sh        /opt/liongard/uninstall
    /opt/liongard-agent/uninstall.sh  /opt/liongard-agent/uninstall
    /usr/local/liongard/uninstall.sh  /usr/local/liongard/uninstall
)
BINARY_PATHS=(
    /usr/local/bin/liongard-agent /usr/bin/liongard-agent
    /usr/local/bin/roaragent      /usr/bin/roaragent
    /usr/local/bin/liongardagent  /usr/bin/liongardagent
)
INSTALL_DIRS=(/opt/liongard /opt/liongard-agent /usr/local/liongard)
# Removed by the install script's pre-uninstall, but kept here until the dev team confirms it
# holds no identity or registration data.
KEPT_DIR=/etc/liongard
IDENTITY_FILE=/etc/liongard-agent/.machine-guid

log_info() { printf '[Uninstall][INFO] %s\n' "$*"; }
log_step() { printf '[Uninstall][STEP] %s\n' "$*"; }
log_ok()   { printf '[Uninstall][OK] %s\n' "$*"; }
log_warn() { printf '[Uninstall][WARN] %s\n' "$*" >&2; }
log_error() { printf '[Uninstall][ERROR] %s\n' "$*" >&2; }

_has_cmd() { command -v "$1" &>/dev/null; }

# Every unit name the script stops, disables and removes.
unit_names() {
    local name
    for name in "${SERVICE_NAMES[@]}"; do printf '%s.service\n' "${name}"; done
    for name in "${UPDATER_NAMES[@]}"; do printf '%s.timer\n%s.service\n' "${name}" "${name}"; done
}

# Prints "deb <name>" or "rpm <name>" for each installed Liongard package. Only packages that are
# really installed count: a .deb removed but with its config left ("rc") doesn't.
installed_packages() {
    if _has_cmd dpkg-query; then
        # shellcheck disable=SC2016  # ${Package} and ${Status} are dpkg-query fields, not shell variables
        dpkg-query -W -f='${Package} ${Status}\n' 2>/dev/null |
            awk '$4 == "installed" && tolower($1) ~ /liongard|roaragent/ { print "deb " $1 }'
    fi
    if _has_cmd rpm; then
        rpm -qa --qf '%{NAME}\n' 2>/dev/null | grep -iE 'liongard|roaragent' | sed 's/^/rpm /'
    fi
}

# Prints one line for everything that still marks this endpoint as having the agent.
agent_leftovers() {
    local unit dir path name pkg
    while read -r unit; do
        for dir in "${UNIT_DIRS[@]}"; do
            [[ -e "${dir}/${unit}" || -L "${dir}/${unit}" ]] && echo "Unit file ${dir}/${unit}"
        done
        if _has_cmd systemctl && systemctl is-active --quiet "${unit}" 2>/dev/null; then
            echo "Active unit ${unit}"
        fi
    done < <(unit_names)
    if ! _has_cmd systemctl && _has_cmd service; then
        for name in "${SERVICE_NAMES[@]}"; do
            service "${name}" status &>/dev/null && echo "Service ${name} (SysV)"
        done
    fi
    for name in "${PROCESS_NAMES[@]}"; do
        pgrep -x "${name}" &>/dev/null && echo "Process ${name}"
    done
    pgrep -f '^/opt/liongard/' &>/dev/null && echo "Processes running from /opt/liongard"
    while read -r pkg; do
        [[ -n "${pkg}" ]] && echo "Package ${pkg}"
    done < <(installed_packages)
    for path in "${BINARY_PATHS[@]}"; do
        [[ -e "${path}" ]] && echo "Binary ${path}"
    done
    for dir in "${INSTALL_DIRS[@]}"; do
        [[ -e "${dir}" ]] && echo "Folder ${dir}"
    done
    return 0
}

stop_services() {
    local unit name
    if _has_cmd systemctl; then
        while read -r unit; do
            if systemctl is-active --quiet "${unit}" 2>/dev/null; then
                log_info "Stopping ${unit}"
                systemctl stop "${unit}" 2>/dev/null || log_warn "Could not stop ${unit}."
            fi
            if systemctl is-enabled --quiet "${unit}" 2>/dev/null; then
                log_info "Disabling ${unit}"
                systemctl disable "${unit}" 2>/dev/null || log_warn "Could not disable ${unit}."
            fi
        done < <(unit_names)
    elif _has_cmd service; then
        for name in "${SERVICE_NAMES[@]}"; do
            service "${name}" stop &>/dev/null || true
        done
    fi
}

# Removes installed packages by their real names. "remove", not "purge": a package could own
# files under /etc that the agent needs to keep (its identity), which is not confirmed yet.
remove_packages() {
    local kind name rc
    while read -r kind name; do
        [[ -z "${name}" ]] && continue
        log_info "Removing ${kind} package ${name}"
        rc=0
        if [[ "${kind}" == deb ]]; then
            if _has_cmd apt-get; then DEBIAN_FRONTEND=noninteractive apt-get remove -y "${name}" </dev/null &>/dev/null || rc=$?
            else dpkg --remove "${name}" </dev/null &>/dev/null || rc=$?
            fi
        elif _has_cmd dnf;    then dnf remove -y "${name}" </dev/null &>/dev/null || rc=$?
        elif _has_cmd yum;    then yum remove -y "${name}" </dev/null &>/dev/null || rc=$?
        elif _has_cmd zypper; then zypper --non-interactive remove "${name}" </dev/null &>/dev/null || rc=$?
        else rpm -e "${name}" </dev/null &>/dev/null || rc=$?
        fi
        if [[ "${rc}" -eq 0 ]]; then log_ok "Removed package ${name}."
        else log_warn "Removing package ${name} returned ${rc}."
        fi
    done < <(installed_packages)
}

stop_processes() {
    local name
    for name in "${PROCESS_NAMES[@]}"; do
        pkill -x "${name}" &>/dev/null && log_info "Stopped process ${name}."
    done
    # The agent's node and prowl children run from /opt/liongard.
    pkill -f '^/opt/liongard/' &>/dev/null && log_info "Stopped processes running from /opt/liongard."
    sleep 2
    for name in "${PROCESS_NAMES[@]}"; do pkill -9 -x "${name}" &>/dev/null; done
    pkill -9 -f '^/opt/liongard/' &>/dev/null
    return 0
}

remove_units() {
    local unit dir link
    while read -r unit; do
        for dir in "${UNIT_DIRS[@]}"; do
            if [[ -e "${dir}/${unit}" || -L "${dir}/${unit}" ]]; then
                log_info "Removing unit file ${dir}/${unit}"
                rm -f -- "${dir}/${unit}" || log_warn "Could not remove ${dir}/${unit}."
            fi
        done
        # Enable symlinks left behind if the unit couldn't be disabled.
        for link in /etc/systemd/system/*.wants/"${unit}"; do
            [[ -L "${link}" ]] && rm -f -- "${link}"
        done
    done < <(unit_names)
    if _has_cmd systemctl; then
        systemctl daemon-reload 2>/dev/null || true
        while read -r unit; do systemctl reset-failed "${unit}" &>/dev/null || true; done < <(unit_names)
    fi
}

run_agent_uninstall_scripts() {
    local script
    for script in "${AGENT_UNINSTALL_SCRIPTS[@]}"; do
        if [[ -x "${script}" ]]; then
            log_info "Running agent uninstall script: ${script}"
            "${script}" </dev/null &>/dev/null || log_warn "${script} returned $?."
        fi
    done
}

remove_files() {
    local path
    for path in "${BINARY_PATHS[@]}" "${INSTALL_DIRS[@]}"; do
        if [[ -e "${path}" || -L "${path}" ]]; then
            log_info "Removing ${path}"
            rm -rf -- "${path}" || log_warn "Could not remove ${path}."
        fi
    done
}

# ============================================================
# MAIN
# ============================================================

if [[ "${EUID}" -ne 0 ]]; then
    log_error "Run this script as root (for example with sudo)."
    exit 1
fi

log_info "Local removal only: no Liongard API calls, and the platform record is kept."

before="$(agent_leftovers)"
if [[ -z "${before}" ]]; then
    log_ok "No Liongard Agent found. Nothing to remove."
else
    log_info "Found:"
    while read -r line; do log_info "  - ${line}"; done <<< "${before}"

    log_step "Stopping services and the updater timer."
    stop_services
    log_step "Removing packages."
    remove_packages
    log_step "Stopping processes."
    stop_processes
    log_step "Removing unit files."
    remove_units
    run_agent_uninstall_scripts
    log_step "Removing binaries and install folders."
    remove_files
fi

if [[ -e "${KEPT_DIR}" ]]; then
    log_warn "${KEPT_DIR} was left in place until the dev team confirms what it holds. Remove it by hand if you don't need it."
fi
if [[ -f "${IDENTITY_FILE}" ]]; then
    log_info "Agent identity ${IDENTITY_FILE} preserved (not modified by this script). Present: yes"
else
    log_info "Agent identity ${IDENTITY_FILE} preserved (not modified by this script). Present: no"
fi

[[ -z "${before}" ]] && exit 0

after="$(agent_leftovers)"
if [[ -z "${after}" ]]; then
    log_ok "The Liongard Agent was removed. Nothing is left."
    exit 0
fi

log_warn "The Liongard Agent is still detected. Left on this endpoint:"
while read -r line; do log_warn "  - ${line}"; done <<< "${after}"
exit 1
