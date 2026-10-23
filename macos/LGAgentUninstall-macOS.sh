#!/bin/bash

# SYNOPSIS
#   Removes the Liongard Agent from a Mac (local removal only).
#
# DESCRIPTION
#   Uninstalls the Liongard Agent and removes what it leaves behind. There are no settings to
#   fill in. Exit codes and troubleshooting are in the README under LINK.
#   - Runs the package's own /Library/Liongard/uninstall.sh when present, then always stops and
#     removes both LaunchDaemons, leftover processes, /Library/Liongard and the package receipts,
#     and reports anything that's left.
#   - Removes leftover /tmp settings files from earlier installs.
#   - Makes no Liongard API calls and keeps the agent's record on the platform. Platform removal
#     isn't included; on Windows, LGAgentUninstall-Advanced.ps1 does it.
#   - Never touches the agent identity (/etc/liongard-agent), so a later reinstall re-attaches
#     to the same platform record.
#
# NOTES
#   Requires:     root, macOS on Intel or Apple Silicon. No tokens.
#   Author:       Liongard Partner Support
#   Last updated: 2026-10-23
#
# LINK
#   https://github.com/liongard/agent-scripts/blob/main/macos/README.md

AGENT_DIR=/Library/Liongard
PKG_UNINSTALL="$AGENT_DIR/uninstall.sh"
LABELS=(com.liongard.liongard-agent com.liongard.liongard-agent-updater)
# Receipts of the outer and the inner package.
RECEIPTS=(com.liongard.LiongardAgent com.liongard.liongard-agent.app)
# Settings handoff files the package reads, and the file the installer UI leaves behind.
# /tmp/liongard-agent-installer.log is kept for troubleshooting.
TMP_FILES=(
  /tmp/liongard_instance_url
  /tmp/liongard_access_key_id
  /tmp/liongard_access_key_secret
  /tmp/liongard_name
  /tmp/liongard_environment
  /tmp/liongard_description
  /tmp/temporary-liongard-values.txt
)
IDENTITY_FILE=/etc/liongard-agent/.machine-guid

log_info() {
  echo "INFO: $1"
}

log_warn() {
  echo "WARN: $1" >&2
}

log_error() {
  echo "ERROR: $1" >&2
}

# Prints one line for everything that still marks this Mac as having the agent.
agent_leftovers() {
  local label receipt
  for label in "${LABELS[@]}"
  do
    if launchctl print "system/$label" > /dev/null 2>&1
    then
      echo "Loaded service system/$label"
    fi
    if [ -e "/Library/LaunchDaemons/$label.plist" ]
    then
      echo "LaunchDaemon /Library/LaunchDaemons/$label.plist"
    fi
  done
  if pgrep -f "^$AGENT_DIR/" > /dev/null 2>&1
  then
    echo "Processes running from $AGENT_DIR"
  fi
  if [ -e "$AGENT_DIR" ]
  then
    echo "Folder $AGENT_DIR"
  fi
  for receipt in "${RECEIPTS[@]}"
  do
    if pkgutil --pkg-info "$receipt" > /dev/null 2>&1
    then
      echo "Package receipt $receipt"
    fi
  done
}

# True when the group or other users can write to the path, or its mode can't be read.
writable_by_others() {
  local mode
  mode=$(stat -f %Lp "$1" 2>/dev/null) || return 0
  [ $(( 8#$mode & 8#022 )) -ne 0 ]
}

if [ "$EUID" -ne 0 ]
then
  log_error "run this script as root (for example with sudo)."
  exit 1
fi

log_info "Local removal only: no Liongard API calls, and the platform record is kept."

before=$(agent_leftovers)
if [ -z "$before" ]
then
  log_info "No Liongard Agent found. Nothing to remove."
else
  log_info "Found:"
  echo "$before" | while read -r line; do log_info "  - $line"; done

  # The package's own script stops and removes both services only when they're loaded, so the
  # steps after it always run. It's run only when it's a root-owned file nobody else can change,
  # in a folder nobody else can change.
  if [ -e "$PKG_UNINSTALL" ] && { [ -L "$AGENT_DIR" ] || writable_by_others "$AGENT_DIR"; }
  then
    log_warn "$AGENT_DIR is a symlink or can be changed by users other than root, so $PKG_UNINSTALL was not run."
  elif [ -f "$PKG_UNINSTALL" ] && [ ! -L "$PKG_UNINSTALL" ] && [ -O "$PKG_UNINSTALL" ] \
    && ! writable_by_others "$PKG_UNINSTALL"
  then
    log_info "Running $PKG_UNINSTALL"
    /bin/zsh "$PKG_UNINSTALL" < /dev/null
    log_info "$PKG_UNINSTALL exited with $?. Completing the removal."
  elif [ -e "$PKG_UNINSTALL" ]
  then
    log_warn "$PKG_UNINSTALL isn't a root-owned file that only root can change, so it was not run."
  fi

  for label in "${LABELS[@]}"
  do
    if launchctl print "system/$label" > /dev/null 2>&1
    then
      log_info "Stopping system/$label"
      launchctl bootout "system/$label" > /dev/null 2>&1 || log_warn "launchctl bootout system/$label failed."
    fi
    if [ -e "/Library/LaunchDaemons/$label.plist" ] || [ -L "/Library/LaunchDaemons/$label.plist" ]
    then
      log_info "Removing /Library/LaunchDaemons/$label.plist"
      rm -f "/Library/LaunchDaemons/$label.plist" || log_warn "could not remove /Library/LaunchDaemons/$label.plist."
    fi
  done

  if pkill -f "^$AGENT_DIR/" > /dev/null 2>&1
  then
    log_info "Stopped processes running from $AGENT_DIR."
    sleep 2
    pkill -9 -f "^$AGENT_DIR/" > /dev/null 2>&1
  fi

  if [ -e "$AGENT_DIR" ] || [ -L "$AGENT_DIR" ]
  then
    log_info "Removing $AGENT_DIR"
    rm -rf "$AGENT_DIR" || log_warn "could not remove $AGENT_DIR."
  fi

  for receipt in "${RECEIPTS[@]}"
  do
    if pkgutil --pkg-info "$receipt" > /dev/null 2>&1
    then
      log_info "Forgetting package receipt $receipt"
      pkgutil --forget "$receipt" > /dev/null 2>&1 || log_warn "pkgutil --forget $receipt failed."
    fi
  done
fi

# Deleting a symlink removes only the link.
for f in "${TMP_FILES[@]}"
do
  if [ -e "$f" ] || [ -L "$f" ]
  then
    log_info "Removing $f"
    rm -f "$f" || log_warn "could not remove $f."
  fi
done

if [ -f "$IDENTITY_FILE" ]
then
  log_info "Agent identity $IDENTITY_FILE preserved (not modified by this script). Present: yes"
else
  log_info "Agent identity $IDENTITY_FILE preserved (not modified by this script). Present: no"
fi

if [ -z "$before" ]
then
  exit 0
fi

after=$(agent_leftovers)
if [ -z "$after" ]
then
  log_info "The Liongard Agent was removed. Nothing is left."
  exit 0
fi

log_error "the Liongard Agent is still detected. Left on this Mac:"
echo "$after" | while read -r line; do log_error "  - $line"; done
exit 1
