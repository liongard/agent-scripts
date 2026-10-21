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
#   - If registration fails because ENVIRONMENT does not exist in Liongard, installs once more
#     without it and logs a WARN.
#   - Confirms the agent is running after the install.
#
# NOTES
#   Requires:     root, macOS on Intel or Apple Silicon.
#                 Liongard agent install token (key and secret).
#   Author:       Liongard Partner Support
#   Last updated: 2026-10-21
#
# LINK
#   https://github.com/liongard/agent-scripts/blob/main/macos/README.md

####################################################################################################
#                                          Variables                                               #
####################################################################################################

# Enter the corresponding values for the following variables:
#
# INSTANCE_URL (required): your Liongard instance. Accepts us1, us1.app.liongard.com or
#   https://us1.app.liongard.com, and is passed to the package as us1.app.liongard.com.
# ACCESS_KEY_ID (required): The access key ID generated in the platform for agent installs
# ACCESS_KEY_SECRET (required): The access key secret generated in the platform for agent installs
#   The three required values are needed only for a new install. A value still set to its
#   REPLACE_WITH_* placeholder counts as blank.
# NAME (optional): The name you would like to give to the agent. If one is not provided, then the
#   agent's name will default to the hostname
# ENVIRONMENT (optional): The name of the environment you would like the agent to be assigned to.
#   This must match the environment name in the platform exactly. If one is not provided, then the
#   agent will be registered without an environment assignment. If it does not exist in the
#   platform, the script installs the agent without an environment and logs a WARN.
# AGENT_DESCRIPTION (optional): A free-text description for the agent. Requires an agent package
#   of version 5.5.0 or newer.
#   Leave the optional values blank if you don't use them. The script stops if one starts with
#   REPLACE_WITH_.
#
# NAME, ENVIRONMENT and AGENT_DESCRIPTION only apply to a new install. The package skips
# registration when /Library/Liongard/.config.json already exists.
#
# MAC_ARCHITECTURE (optional): which package to install. "auto" (default) picks the Apple Silicon
#   package on Apple Silicon and the Intel package on Intel Macs. "x64" or "arm64" forces one. The
#   Intel package on Apple Silicon needs Rosetta 2, which the script installs if it's missing.
# PKG_PATH (optional): full path to a .pkg already on this Mac, for example one staged by your MDM.
#   When set, the script installs it instead of downloading.

INSTANCE_URL=REPLACE_WITH_INSTANCE_URL
ACCESS_KEY_ID=REPLACE_WITH_ACCESS_KEY_ID
ACCESS_KEY_SECRET=REPLACE_WITH_ACCESS_KEY_SECRET
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

# Missing-environment retry. UNCONFIRMED: the exact registration error for an environment that
# does not exist in Liongard is not known yet; this pattern is a best guess and will be tightened
# once QA captures the real message. Only a failed install whose package log matches it is retried
# (once, without the environment).
MISSING_ENVIRONMENT_PATTERN="environment.{0,80}(does[[:space:]]*not|doesn'?t|not)[[:space:]]+exist"

log_info() {
  echo "INFO: $1"
}

log_warn() {
  echo "WARN: $1"
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

# Optional values default to blank, so a REPLACE_WITH_* value there is a mistake.
for setting in NAME ENVIRONMENT AGENT_DESCRIPTION
do
  case "${!setting}" in
    REPLACE_WITH_*)
      log_error "$setting is still set to a REPLACE_WITH_* placeholder. Set a value or leave it blank."
      exit 1
      ;;
  esac
done

# A required value still set to its placeholder counts as blank.
for setting in INSTANCE_URL ACCESS_KEY_ID ACCESS_KEY_SECRET
do
  case "${!setting}" in
    REPLACE_WITH_*) printf -v "$setting" '%s' "" ;;
  esac
done

# Without an existing config the package registers a new agent, which needs all three values.
if [ ! -f "$AGENT_CONFIG" ]
then
  missing=""
  for setting in INSTANCE_URL ACCESS_KEY_ID ACCESS_KEY_SECRET
  do
    if [ -z "${!setting}" ]
    then
      missing="${missing:+$missing, }$setting"
    fi
  done
  if [ -n "$missing" ]
  then
    log_error "$missing must be set for a new install (blank or still a REPLACE_WITH_* placeholder)."
    exit 1
  fi
fi

# The package expects the instance host (us1.app.liongard.com). Accepts us1,
# us1.app.liongard.com or https://us1.app.liongard.com in any case, with surrounding
# spaces, http:// or a trailing slash or path.
if [ -n "$INSTANCE_URL" ]
then
  case "$INSTANCE_URL" in
    *[?*[\]]*)
      log_error "INSTANCE_URL '$INSTANCE_URL' contains a placeholder character. Provide a valid instance (e.g. us1.app.liongard.com)."
      exit 1
      ;;
  esac
  instance=$(printf '%s' "$INSTANCE_URL" | tr '[:upper:]' '[:lower:]')
  instance="${instance#"${instance%%[![:space:]]*}"}"
  instance="${instance%"${instance##*[![:space:]]}"}"
  instance="${instance#https://}"
  instance="${instance#http://}"
  instance="${instance%%/*}"
  instance="${instance%.app.liongard.com}"
  if ! [[ "$instance" =~ ^[a-z0-9-]+$ ]]
  then
    log_error "INSTANCE_URL '$INSTANCE_URL' is not a Liongard instance such as us1, us1.app.liongard.com or https://us1.app.liongard.com."
    exit 1
  fi
  INSTANCE_URL="${instance}.app.liongard.com"
  log_info "Liongard instance: $INSTANCE_URL"
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

# Writes the handoff files. $1 is the environment to hand over ("" leaves it out).
lg_write_settings() {
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

  if [ -n "$1" ]
  then
    lg_write "$1" /tmp/liongard_environment
  fi

  if [ -n "$AGENT_DESCRIPTION" ]
  then
    lg_write "${AGENT_DESCRIPTION}" /tmp/liongard_description
  fi

  if [ -e "$LG_VALUES_FILE" ] || [ -L "$LG_VALUES_FILE" ]
  then
    log_error "$LG_VALUES_FILE appeared during the run. Refusing to continue."
    exit 1
  fi
}

# Runs installer and sets $status. LG_LOG_START is the package log's size before the run, so
# only this run's lines are searched afterwards.
lg_run_installer() {
  LG_LOG_START=$(stat -f%z "$LG_INSTALL_LOG" 2>/dev/null || echo 0)
  installer -pkg "$PKG" -target /
  status=$?
}

# Prints the first line this run added to the package log that matches
# MISSING_ENVIRONMENT_PATTERN. Lines echoing the registration request are skipped, so an
# environment name that itself contains the words can't trigger a retry.
lg_missing_environment_line() {
  tail -c +"$((LG_LOG_START + 1))" "$LG_INSTALL_LOG" 2>/dev/null \
    | grep -v 'API Request:' \
    | grep -Ei -m 1 "$MISSING_ENVIRONMENT_PATTERN" \
    | cut -c 1-300
}

lg_write_settings "$ENVIRONMENT"

had_config=0
if [ -f "$AGENT_CONFIG" ]
then
  had_config=1
  log_info "An agent config already exists, so the package will keep the existing registration."
fi

environment_warning=""
log_info "Running the installer."
lg_run_installer

# A failed registration removes /Library/Liongard (so no agent config is left) and the handoff
# files, and the package registers again on the next run. So when the package log says the
# environment does not exist, it's safe to install once more without it.
if [ "$status" -ne 0 ] && [ -n "$ENVIRONMENT" ] && [ "$had_config" = "0" ] && [ ! -e "$AGENT_CONFIG" ]
then
  missing_line=$(lg_missing_environment_line)
  if [ -n "$missing_line" ]
  then
    log_warn "Environment '$ENVIRONMENT' was not found in Liongard ($missing_line). Installing again without an environment; assign it in Liongard afterwards."
    environment_warning="Environment '$ENVIRONMENT' was not found in Liongard. The agent was installed without an environment; assign it in Liongard."
    for f in "${LG_FILES[@]}"
    do
      lg_remove_checked "$f"
    done
    lg_write_settings ""
    log_info "Running the installer again without an environment."
    lg_run_installer
  fi
fi

if [ "$status" -ne 0 ]
then
  log_error "the installer exited with $status. See $LG_INSTALL_LOG and /var/log/install.log."
  if [ -n "$environment_warning" ]
  then
    log_error "the retry without environment '$ENVIRONMENT' failed too."
  fi
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
if [ -n "$environment_warning" ]
then
  log_warn "$environment_warning"
fi
exit 0
