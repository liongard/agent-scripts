#!/bin/bash

####################################################################################################
#                                 Liongard Agent Install Script                                    #
####################################################################################################

# Use this script to install the Liongard Agent. This script allows the setting of improtant
# environment variables before invoking the installer.

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

INSTANCE_URL=
ACCESS_KEY_ID=
ACCESS_KEY_SECRET=
NAME=
ENVIRONMENT=

####################################################################################################
#                                     Installation Logic                                           #
####################################################################################################

# The script from this point onwards is responsible for setting environment variables before
# invoking the installer to install the LiongardAgent.pkg file. After the installation, the script
# will unset these environment variables. DO NOT MODIFY the script beyond this point. If the
# installation is not working, please contact Liongard support.

# The .pkg postinstall reads these five fixed paths, so every run clears them (refusing
# symlinks and files not owned by root), writes them root-only, and deletes them on exit.
LG_FILES=(
  /tmp/liongard_instance_url
  /tmp/liongard_access_key_id
  /tmp/liongard_access_key_secret
  /tmp/liongard_name
  /tmp/liongard_environment
)
LG_TMP=""

if [ "$EUID" -ne 0 ]
then
  echo "ERROR: run this script as root (for example with sudo)." >&2
  exit 1
fi

umask 077

for f in "${LG_FILES[@]}"
do
  if [ -L "$f" ]
  then
    echo "ERROR: $f is a symlink. Refusing to continue; investigate and remove it as root." >&2
    exit 1
  fi
  if [ -e "$f" ] && [ ! -O "$f" ]
  then
    echo "ERROR: $f exists and is not owned by root. Refusing to continue; investigate and remove it as root." >&2
    exit 1
  fi
  if ! rm -f "$f" || [ -e "$f" ]
  then
    echo "ERROR: could not remove existing $f." >&2
    exit 1
  fi
done

# shellcheck disable=SC2329 # Invoked from the traps below.
lg_cleanup() {
  if [ -n "$LG_TMP" ]
  then
    rm -f "$LG_TMP"
  fi
  rm -f "${LG_FILES[@]}"
}
trap 'lg_cleanup' EXIT
trap 'lg_cleanup; trap - EXIT; exit 130' INT
trap 'lg_cleanup; trap - EXIT; exit 143' TERM

# Writes $1 to a new root-only temp file, then renames it onto $2. rename(2) replaces a
# planted symlink instead of following it.
lg_write() {
  if [ -e "$2" ] || [ -L "$2" ]
  then
    echo "ERROR: $2 appeared after the pre-run cleanup. Refusing to continue." >&2
    exit 1
  fi
  LG_TMP=$(mktemp /tmp/liongard.XXXXXXXX) || { echo "ERROR: mktemp failed." >&2; exit 1; }
  if ! echo "$1" > "$LG_TMP" || ! chown root:wheel "$LG_TMP" || ! chmod 600 "$LG_TMP" || ! mv -f "$LG_TMP" "$2"
  then
    echo "ERROR: could not write $2." >&2
    exit 1
  fi
  LG_TMP=""
  if [ -L "$2" ] || [ ! -f "$2" ] || [ ! -O "$2" ]
  then
    echo "ERROR: $2 is not a root-owned regular file after writing." >&2
    exit 1
  fi
}

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

installer -pkg Liongard-lts.pkg -target /
status=$?
exit "$status"
