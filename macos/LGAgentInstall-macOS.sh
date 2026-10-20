#!/bin/bash

# SYNOPSIS
#   Installs the Liongard Agent on macOS (Intel or Apple Silicon).
#
# DESCRIPTION
#   Installs the Liongard Agent and registers it with your Liongard instance.
#   Set your values in the Variables block below. Exit codes, logs and troubleshooting are in
#   the README under LINK.
#   - Exits 0 without changes if the agent is already installed and running.
#   - Downloads the Intel or Apple Silicon package (or uses PKG_PATH) and checks its size and
#     Liongard signature.
#   - Installs Rosetta 2 only when the Intel package is used on Apple Silicon.
#   - Hands the settings to the package in root-only files in /tmp and deletes them on exit.
#   - Confirms the agent is running after the install.
#
# NOTES
#   Requires:     root, macOS on Intel or Apple Silicon.
#                 Liongard agent install token (key and secret).
#   Author:       Liongard Partner Support
#   Last updated: 2026-10-20
#
# LINK
#   https://github.com/liongard/agent-scripts/blob/main/macos/README.md

####################################################################################################
#                                          Variables                                               #
####################################################################################################

# Enter the corresponding values for the following variables:
#
# INSTANCE_URL (required):The instance URL of your liongard instance. Should be in the format
#   <instance>.app.liongard.com (ex: us1.app.liongard.com)
# ACCESS_KEY_ID (required): The access key ID generated in the platform for agent installs
# ACCESS_KEY_SECRET (required): The access key secret generated in the platform for agent installs
# NAME (optional): The name you would like to give to the agent. If one is not provided, then the
#   agent's name will default to the hostname
# ENVIRONMENT (optional): The name of the environment you would like the agent to be assigned to.
#   This must match the environment name in the platform exactly. If one is not provided, then the
#   agent will be registered without an environment assignment.
# AGENT_DESCRIPTION (optional): A free-text description for the agent. Requires an agent package
#   of version 5.5.0 or newer.
#
# NAME, ENVIRONMENT and AGENT_DESCRIPTION only apply to a new install. The package skips
# registration when /Library/Liongard/.config.json already exists.
#
# MAC_ARCHITECTURE (optional): which package to install. "auto" (default) picks the Apple Silicon
#   package on Apple Silicon and the Intel package on Intel Macs. "x64" or "arm64" forces one. The
#   Intel package on Apple Silicon needs Rosetta 2, which the script installs if it's missing.
# PKG_PATH (optional): full path to a .pkg already on this Mac, for example one staged by your MDM.
#   When set, the script installs it instead of downloading.

INSTANCE_URL=
ACCESS_KEY_ID=
ACCESS_KEY_SECRET=
NAME=
ENVIRONMENT=
AGENT_DESCRIPTION=
MAC_ARCHITECTURE=auto
PKG_PATH=

####################################################################################################
#                                     Installation Logic                                           #
####################################################################################################

# The script from this point onwards downloads and checks the Liongard Agent package, hands the
# settings above to it and runs the installer. DO NOT MODIFY the script beyond this point. If the
# installation is not working, please contact Liongard support.

PKG_URL_X64="https://agents.static.liongard.com/LiongardAgent-lts.pkg"
PKG_URL_ARM64="https://agents.static.liongard.com/LiongardAgent-lts-arm64.pkg"
PKG_MIN_BYTES=20000000
PKG_TEAM_ID="KU4C98N3LW"
DOWNLOAD_ATTEMPTS=3

AGENT_PLIST=/Library/LaunchDaemons/com.liongard.liongard-agent.plist
AGENT_SERVICE=system/com.liongard.liongard-agent
AGENT_CONFIG=/Library/Liongard/.config.json

# The .pkg reads these six fixed paths, so every run clears them (refusing symlinks and files
# not owned by root), writes them root-only, and deletes them on exit.
LG_FILES=(
  /tmp/liongard_instance_url
  /tmp/liongard_access_key_id
  /tmp/liongard_access_key_secret
  /tmp/liongard_name
  /tmp/liongard_environment
  /tmp/liongard_description
)
# Left behind by an earlier install from the installer UI. Removed so the installer uses only
# this run's values.
LG_VALUES_FILE=/tmp/temporary-liongard-values.txt
# The package appends its own log here. The script creates it root-only before the install.
LG_INSTALL_LOG=/tmp/liongard-agent-installer.log
LG_TMP=""
WORK_DIR=""

log_info() {
  echo "INFO: $1"
}

log_error() {
  echo "ERROR: $1" >&2
}

# Prints the AGENT_VERSION from the agent config, or "unknown".
installed_version() {
  local v=""
  if [ -f "$AGENT_CONFIG" ]
  then
    v=$(sed -n 's/.*"AGENT_VERSION"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$AGENT_CONFIG" 2>/dev/null | head -1)
  fi
  echo "${v:-unknown}"
}

agent_running() {
  [ -f "$AGENT_PLIST" ] && launchctl print "$AGENT_SERVICE" > /dev/null 2>&1
}

if [ "$EUID" -ne 0 ]
then
  log_error "run this script as root (for example with sudo)."
  exit 1
fi

umask 077

if agent_running
then
  log_info "The Liongard Agent is already installed and running (version $(installed_version))."
  log_info "No registration values were applied (INSTANCE_URL, ACCESS_KEY_ID, ACCESS_KEY_SECRET, NAME, ENVIRONMENT, AGENT_DESCRIPTION)."
  exit 0
fi

# Without an existing config the package registers a new agent, which needs all three values.
if [ ! -f "$AGENT_CONFIG" ] && { [ -z "$INSTANCE_URL" ] || [ -z "$ACCESS_KEY_ID" ] || [ -z "$ACCESS_KEY_SECRET" ]; }
then
  log_error "INSTANCE_URL, ACCESS_KEY_ID and ACCESS_KEY_SECRET are required for a new install."
  exit 1
fi

if [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = "1" ]
then
  HOST_ARCH=arm64
else
  HOST_ARCH=x64
fi

case "$MAC_ARCHITECTURE" in
  auto) PKG_ARCH="$HOST_ARCH" ;;
  x64|arm64) PKG_ARCH="$MAC_ARCHITECTURE" ;;
  *)
    log_error "MAC_ARCHITECTURE must be auto, x64 or arm64 (got '$MAC_ARCHITECTURE')."
    exit 1
    ;;
esac

if [ "$HOST_ARCH" = "x64" ] && [ "$PKG_ARCH" = "arm64" ]
then
  log_error "MAC_ARCHITECTURE=arm64 can't be installed on an Intel Mac."
  exit 1
fi

# Refuses symlinks and files not owned by root, then deletes the file.
lg_remove_checked() {
  if [ -L "$1" ]
  then
    log_error "$1 is a symlink. Refusing to continue; investigate and remove it as root."
    exit 1
  fi
  if [ -e "$1" ] && [ ! -O "$1" ]
  then
    log_error "$1 exists and is not owned by root. Refusing to continue; investigate and remove it as root."
    exit 1
  fi
  if ! rm -f "$1" || [ -e "$1" ]
  then
    log_error "could not remove existing $1."
    exit 1
  fi
}

for f in "${LG_FILES[@]}"
do
  lg_remove_checked "$f"
done

# A leftover from the installer UI may belong to the user who ran it, so it's deleted
# without the ownership check. Deleting a symlink removes only the link.
if [ -e "$LG_VALUES_FILE" ] || [ -L "$LG_VALUES_FILE" ]
then
  log_info "Removing $LG_VALUES_FILE left by an earlier install."
  if ! rm -f "$LG_VALUES_FILE" || [ -e "$LG_VALUES_FILE" ] || [ -L "$LG_VALUES_FILE" ]
  then
    log_error "could not remove $LG_VALUES_FILE."
    exit 1
  fi
fi

# shellcheck disable=SC2329 # Invoked from the traps below.
lg_cleanup() {
  if [ -n "$LG_TMP" ]
  then
    rm -f "$LG_TMP"
  fi
  rm -f "${LG_FILES[@]}"
  if [ -n "$WORK_DIR" ]
  then
    rm -rf "$WORK_DIR"
  fi
}
trap 'lg_cleanup' EXIT
trap 'lg_cleanup; trap - EXIT; exit 130' INT
trap 'lg_cleanup; trap - EXIT; exit 143' TERM

# Writes $1 to a new root-only temp file, then renames it onto $2. rename(2) replaces a
# planted symlink instead of following it.
lg_write() {
  if [ -e "$2" ] || [ -L "$2" ]
  then
    log_error "$2 appeared after the pre-run cleanup. Refusing to continue."
    exit 1
  fi
  LG_TMP=$(mktemp /tmp/liongard.XXXXXXXX) || { log_error "mktemp failed."; exit 1; }
  if ! echo "$1" > "$LG_TMP" || ! chown root:wheel "$LG_TMP" || ! chmod 600 "$LG_TMP" || ! mv -f "$LG_TMP" "$2"
  then
    log_error "could not write $2."
    exit 1
  fi
  LG_TMP=""
  if [ -L "$2" ] || [ ! -f "$2" ] || [ ! -O "$2" ]
  then
    log_error "$2 is not a root-owned regular file after writing."
    exit 1
  fi
}

# Keeps an existing root-owned log (restricted to root), otherwise creates a new empty one.
if [ -e "$LG_INSTALL_LOG" ] && [ ! -L "$LG_INSTALL_LOG" ] && [ -f "$LG_INSTALL_LOG" ] && [ -O "$LG_INSTALL_LOG" ]
then
  chmod 600 "$LG_INSTALL_LOG" || { log_error "could not restrict $LG_INSTALL_LOG."; exit 1; }
else
  lg_remove_checked "$LG_INSTALL_LOG"
  lg_write "" "$LG_INSTALL_LOG"
fi

WORK_DIR=$(mktemp -d /tmp/liongard-pkg.XXXXXXXX) || { log_error "mktemp -d failed."; WORK_DIR=""; exit 1; }
PKG="$WORK_DIR/LiongardAgent.pkg"

if [ -n "$PKG_PATH" ]
then
  if [ ! -f "$PKG_PATH" ]
  then
    log_error "PKG_PATH '$PKG_PATH' is not a file."
    exit 1
  fi
  # Copied first, so the file that's checked is the file that's installed.
  log_info "Using the local package $PKG_PATH."
  if ! cp "$PKG_PATH" "$PKG"
  then
    log_error "could not copy $PKG_PATH."
    exit 1
  fi
else
  if [ "$PKG_ARCH" = "arm64" ]
  then
    PKG_URL="$PKG_URL_ARM64"
  else
    PKG_URL="$PKG_URL_X64"
  fi
  log_info "Downloading $PKG_URL."
  attempt=1
  while :
  do
    expected=$(curl -sSfIL --connect-timeout 30 "$PKG_URL" 2>/dev/null | tr -d '\r' | awk 'tolower($1)=="content-length:"{v=$2} END{print v}')
    if curl -sSfL --connect-timeout 30 --retry 2 --retry-delay 5 -o "$PKG" "$PKG_URL"
    then
      actual=$(stat -f%z "$PKG" 2>/dev/null)
      if [ -n "$expected" ] && [ "$actual" != "$expected" ]
      then
        log_error "downloaded $actual bytes, expected $expected (attempt $attempt)."
      else
        break
      fi
    else
      log_error "download failed (attempt $attempt)."
    fi
    if [ "$attempt" -ge "$DOWNLOAD_ATTEMPTS" ]
    then
      log_error "could not download $PKG_URL after $DOWNLOAD_ATTEMPTS attempts."
      exit 1
    fi
    attempt=$((attempt + 1))
    sleep 10
  done
fi

size=$(stat -f%z "$PKG" 2>/dev/null)
if [ -z "$size" ] || [ "$size" -lt "$PKG_MIN_BYTES" ]
then
  log_error "the package is ${size:-0} bytes, smaller than expected. Refusing to install."
  exit 1
fi

# The leaf certificate must be Liongard's Developer ID Installer certificate.
if ! signature=$(pkgutil --check-signature "$PKG" 2>&1) || ! echo "$signature" | grep -q "^ *1\. Developer ID Installer: .*($PKG_TEAM_ID)$"
then
  log_error "the package is not signed by Liongard (Team ID $PKG_TEAM_ID). Refusing to install."
  echo "$signature" >&2
  exit 1
fi
log_info "Package signature: Developer ID Installer, Team ID $PKG_TEAM_ID."

# TODO(#3): verify the SHA-256 once Liongard publishes .sha256 files for the .pkg installers.
verify_sha256() {
  return 0
}
if ! verify_sha256 "$PKG"
then
  log_error "SHA-256 check failed. Refusing to install."
  exit 1
fi

# The Distribution file says which CPU the package is built for.
if ! xar -xf "$PKG" -C "$WORK_DIR" Distribution 2>/dev/null
then
  log_error "could not read the package's Distribution file."
  exit 1
fi
host_architectures=$(sed -n 's/.*hostArchitectures="\([^"]*\)".*/\1/p' "$WORK_DIR/Distribution" | head -1)
log_info "Package architecture: ${host_architectures:-not set}. This Mac: $HOST_ARCH."

case ",$host_architectures," in
  *,arm64,*) built_for_arm64=1 ;;
  *) built_for_arm64=0 ;;
esac
case ",$host_architectures," in
  *,x86_64,*) built_for_x64=1 ;;
  *) built_for_x64=0 ;;
esac

if [ "$HOST_ARCH" = "x64" ] && [ "$built_for_x64" = "0" ] && [ -n "$host_architectures" ]
then
  log_error "this package is for Apple Silicon and can't be installed on an Intel Mac."
  exit 1
fi

if [ "$HOST_ARCH" = "arm64" ] && [ "$built_for_arm64" = "0" ] && [ -n "$host_architectures" ]
then
  if arch -x86_64 /usr/bin/true > /dev/null 2>&1
  then
    log_info "This is the Intel package; Rosetta 2 is already installed."
  else
    log_info "This is the Intel package; installing Rosetta 2."
    if ! softwareupdate --install-rosetta --agree-to-license || ! arch -x86_64 /usr/bin/true > /dev/null 2>&1
    then
      log_error "could not install Rosetta 2."
      exit 1
    fi
  fi
fi

if [ -n "$INSTANCE_URL" ]
then
  lg_write "${INSTANCE_URL}" /tmp/liongard_instance_url
fi

if [ -n "$ACCESS_KEY_ID" ]
then
  lg_write "${ACCESS_KEY_ID}" /tmp/liongard_access_key_id
fi

if [ -n "$ACCESS_KEY_SECRET" ]
then
  lg_write "${ACCESS_KEY_SECRET}" /tmp/liongard_access_key_secret
fi

if [ -n "$NAME" ]
then
  lg_write "${NAME}" /tmp/liongard_name
fi

if [ -n "$ENVIRONMENT" ]
then
  lg_write "${ENVIRONMENT}" /tmp/liongard_environment
fi

if [ -n "$AGENT_DESCRIPTION" ]
then
  lg_write "${AGENT_DESCRIPTION}" /tmp/liongard_description
fi

if [ -f "$AGENT_CONFIG" ]
then
  log_info "An agent config already exists, so the package will keep the existing registration."
fi

if [ -e "$LG_VALUES_FILE" ] || [ -L "$LG_VALUES_FILE" ]
then
  log_error "$LG_VALUES_FILE appeared during the run. Refusing to continue."
  exit 1
fi

log_info "Running the installer."
installer -pkg "$PKG" -target /
status=$?
if [ "$status" -ne 0 ]
then
  log_error "the installer exited with $status. See $LG_INSTALL_LOG and /var/log/install.log."
  exit "$status"
fi

tries=0
until agent_running
do
  tries=$((tries + 1))
  if [ "$tries" -ge 15 ]
  then
    log_error "the installer succeeded, but the agent isn't running ($AGENT_PLIST, $AGENT_SERVICE)."
    exit 1
  fi
  sleep 2
done

log_info "The Liongard Agent is installed and running (version $(installed_version))."
exit 0
