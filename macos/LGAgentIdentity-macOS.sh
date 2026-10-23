#!/bin/zsh

# Saves and restores a Liongard Agent identity so a rebuilt Mac re-attaches to its Agent record.

ROOT_PREFIX="${LIONGARD_IDENTITY_ROOT:-}"
CONFIG_FILE="${ROOT_PREFIX}/Library/Liongard/.config.json"
MACHINE_GUID_DIRECTORY="${ROOT_PREFIX}/etc/liongard-agent"
MACHINE_GUID_FILE="${MACHINE_GUID_DIRECTORY}/.machine-guid"
FORMAT_VERSION=1
SCRIPT_NAME="${0:t}"

usage() {
  cat <<EOF
Usage:
  sudo $SCRIPT_NAME backup [--output DIR] [--id-only]
  sudo $SCRIPT_NAME restore --from DIR [--with-config] [--force] [--dry-run]
  sudo $SCRIPT_NAME show
  $SCRIPT_NAME --help

backup   Saves the agent identity (machine-guid) and, unless --id-only, a copy of
         /Library/Liongard/.config.json into a new folder
         liongard-identity-<host>-<UTC timestamp> inside DIR (default: your home).
         The folder holds the agent's access key and secret: store it securely.
restore  Writes the saved identity to /etc/liongard-agent/.machine-guid before a
         fresh install. Run it on the rebuilt Mac, then install the agent as usual.
show     Prints the current identity, its source, and the non-secret config fields.

Config restore rule:
  restore writes /Library/Liongard/.config.json when --with-config is given, or
  automatically when the backup holds config.json and is flagged legacy_identity=true.
  A legacy identity (hardware UUID, or a config with no MACHINE_GUID) may not exist
  on the platform record, so only the saved config keeps that record. In every other
  case restore writes only the identity and the installer registers again.

Options:
  --output DIR   Parent folder for the backup folder (must exist).
  --id-only      Save the identity only, not the config.
  --from DIR     Backup folder created by "backup".
  --with-config  Also restore config.json (backup must include it).
  --force        Overwrite an installed agent's config or identity.
  --dry-run      Print every action and write nothing.

Exit codes: 0 success, 1 error, 2 usage error.
EOF
}

err() { print -r -- "Error: $1" >&2; }
warn() { print -r -- "Warning: $1" >&2; }
info() { print -r -- "$1"; }
die() { err "$1"; exit 1; }
usageError() { err "$1"; print -r -- "Run '$SCRIPT_NAME --help' for usage." >&2; exit 2; }

isValidMachineGuid() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]
}

isRoot() { [ "$EUID" -eq 0 ]; }

# Same sed as the installer so the tier decision matches it exactly.
readConfigMachineGuid() {
  [ -f "$CONFIG_FILE" ] || return
  sed -n 's/.*"MACHINE_GUID"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG_FILE" 2>/dev/null | head -1 | tr -d '[:space:]'
}

ioregUuid() {
  if (( ${+LIONGARD_IDENTITY_IOREG_UUID} )); then
    print -r -- "$LIONGARD_IDENTITY_IOREG_UUID" | tr -d '[:space:]'
    return
  fi
  ioreg -rd1 -c IOPlatformExpertDevice | grep IOPlatformUUID | awk -F'"' '{print $4}' | tr -d '[:space:]'
}

# Prints "KEY<TAB>value" for each non-secret field; falls back to sed when the JSON does not parse.
readConfigFields() {
  local file="$1" out key value
  local -a keys=(URL AGENT_ID AGENT_NAME AGENT_UID MACHINE_GUID RESPONSE_QUEUE WORK_DIR AGENT_VERSION)
  out=$(JSON="$(<"$file")" KEYS="${(j: :)keys}" osascript -l 'JavaScript' \
    -e 'const env = $.NSProcessInfo.processInfo.environment' \
    -e 'const o = JSON.parse(env.objectForKey("JSON").js)' \
    -e 'env.objectForKey("KEYS").js.split(" ").map(k => k + "\t" + (o[k] === undefined || o[k] === null ? "" : String(o[k]).replace(/[\r\n\t]/g, " "))).join("\n")' 2>/dev/null)
  if [ $? -eq 0 ] && [ -n "$out" ]; then
    print -r -- "$out"
    return 0
  fi
  for key in $keys; do
    value=$(sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "$file" 2>/dev/null | head -1)
    print -r -- "${key}"$'\t'"${value}"
  done
  return 1
}

typeset -gA CFG
loadConfigFields() {
  CFG=()
  CONFIG_PARSED=false
  [ -f "$1" ] || return
  local line
  local fields
  fields=$(readConfigFields "$1") && CONFIG_PARSED=true
  for line in "${(@f)fields}"; do
    CFG[${line%%$'\t'*}]="${line#*$'\t'}"
  done
}

# Fails when a non-root caller cannot see the root-only identity files.
requireReadable() {
  if [ -d "$MACHINE_GUID_DIRECTORY" ] && [ ! -x "$MACHINE_GUID_DIRECTORY" ]; then
    die "Cannot read ${MACHINE_GUID_DIRECTORY}. The identity files are root-only (0600); rerun with sudo."
  fi
  if [ -f "$MACHINE_GUID_FILE" ] && [ ! -r "$MACHINE_GUID_FILE" ]; then
    die "Cannot read ${MACHINE_GUID_FILE}. The identity files are root-only (0600); rerun with sudo."
  fi
  if [ -f "$CONFIG_FILE" ] && [ ! -r "$CONFIG_FILE" ]; then
    die "Cannot read ${CONFIG_FILE}. The config is root-only (0600); rerun with sudo."
  fi
}

# Sets IDENTITY, IDENTITY_SOURCE and LEGACY_IDENTITY using the installer's tier order (no tier 4).
resolveIdentity() {
  local candidate
  IDENTITY="" IDENTITY_SOURCE="" LEGACY_IDENTITY=false

  if [ -f "$CONFIG_FILE" ]; then
    candidate=$(readConfigMachineGuid)
    isValidMachineGuid "$candidate" || LEGACY_IDENTITY=true
  fi

  if [ -f "$MACHINE_GUID_FILE" ]; then
    candidate=$(tr -d '[:space:]' < "$MACHINE_GUID_FILE" 2>/dev/null)
    if [ -n "$candidate" ] && isValidMachineGuid "$candidate"; then
      IDENTITY="$candidate" IDENTITY_SOURCE="tier1-machine-guid-file"
      return 0
    fi
    [ -n "$candidate" ] && warn "Ignoring invalid identity in ${MACHINE_GUID_FILE}."
  fi

  [ -f "$CONFIG_FILE" ] || return 1

  candidate=$(readConfigMachineGuid)
  if [ -n "$candidate" ] && isValidMachineGuid "$candidate"; then
    IDENTITY="$candidate" IDENTITY_SOURCE="tier2-config-machine-guid"
    return 0
  fi
  [ -n "$candidate" ] && warn "Ignoring invalid MACHINE_GUID in ${CONFIG_FILE}."

  candidate=$(ioregUuid)
  if [ -n "$candidate" ] && isValidMachineGuid "$candidate"; then
    IDENTITY="$candidate" IDENTITY_SOURCE="tier3-ioplatformuuid"
    LEGACY_IDENTITY=true
    return 0
  fi
  return 1
}

legacyWarning() {
  warn "This agent's platform record may have no MachineGuid (identity source: ${IDENTITY_SOURCE}, or the config has no MACHINE_GUID)."
  warn "Keep config.json: the identity alone may not re-attach this Mac to its Agent record."
}

sha256Of() { shasum -a 256 "$1" | awk '{print $1}'; }

oneLine() { print -r -- "${1//[$'\r\n']/ }"; }

invokingUserHome() {
  local home=""
  if [ -n "$SUDO_USER" ]; then
    home=$(dscl . -read "/Users/${SUDO_USER}" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
  fi
  print -r -- "${home:-$HOME}"
}

cmdBackup() {
  local outputParent="" idOnly=false
  while (( $# )); do
    case "$1" in
      --output) [ -n "$2" ] || usageError "--output needs a directory."; outputParent="$2"; shift 2 ;;
      --id-only) idOnly=true; shift ;;
      -h|--help) usage; exit 0 ;;
      *) usageError "Unknown backup option: $1" ;;
    esac
  done

  requireReadable

  if [ ! -f "$MACHINE_GUID_FILE" ] && [ ! -f "$CONFIG_FILE" ]; then
    if ! isRoot && [ -z "$ROOT_PREFIX" ]; then
      die "No agent identity or config found. Backup needs root to read the 0600 identity files; rerun with sudo."
    fi
    die "No agent identity (${MACHINE_GUID_FILE}) and no agent config (${CONFIG_FILE}) found. Nothing to back up."
  fi

  if ! resolveIdentity; then
    die "Unable to determine the existing agent's identity. Please contact Liongard for support."
  fi

  [ -z "$outputParent" ] && outputParent=$(invokingUserHome)
  [ -d "$outputParent" ] || die "Output directory ${outputParent} does not exist."

  local host stamp dest
  host=$(hostname -s)
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  dest="${outputParent%/}/liongard-identity-${host}-${stamp}"
  [ -e "$dest" ] && die "${dest} already exists; refusing to overwrite it."

  local configIncluded=false
  [ "$idOnly" = false ] && [ -f "$CONFIG_FILE" ] && configIncluded=true

  local oldUmask
  oldUmask=$(umask)
  umask 077
  mkdir "$dest" || die "Unable to create ${dest}."
  chmod 700 "$dest"

  printf '%s\n' "$IDENTITY" > "${dest}/machine-guid" || die "Unable to write ${dest}/machine-guid."
  chmod 600 "${dest}/machine-guid"

  loadConfigFields "$CONFIG_FILE"
  if [ "$configIncluded" = true ]; then
    cp "$CONFIG_FILE" "${dest}/config.json" || die "Unable to copy ${CONFIG_FILE}."
    chmod 600 "${dest}/config.json"
    [ "$CONFIG_PARSED" = true ] || warn "${CONFIG_FILE} is not valid JSON; copied it as-is."
  fi

  {
    print -r -- "format_version=${FORMAT_VERSION}"
    print -r -- "os=macos"
    print -r -- "hostname=$(oneLine "$host")"
    print -r -- "created_utc=${stamp}"
    print -r -- "identity_source=${IDENTITY_SOURCE}"
    print -r -- "legacy_identity=${LEGACY_IDENTITY}"
    print -r -- "agent_id=$(oneLine "${CFG[AGENT_ID]}")"
    print -r -- "agent_name=$(oneLine "${CFG[AGENT_NAME]}")"
    print -r -- "agent_uid=$(oneLine "${CFG[AGENT_UID]}")"
    print -r -- "url=$(oneLine "${CFG[URL]}")"
    print -r -- "agent_version=$(oneLine "${CFG[AGENT_VERSION]}")"
    print -r -- "config_included=${configIncluded}"
    print -r -- "sha256_machine_guid=$(sha256Of "${dest}/machine-guid")"
    if [ "$configIncluded" = true ]; then
      print -r -- "sha256_config_json=$(sha256Of "${dest}/config.json")"
    fi
  } > "${dest}/manifest.txt" || die "Unable to write ${dest}/manifest.txt."
  chmod 600 "${dest}/manifest.txt"
  umask "$oldUmask"

  if isRoot && [ -n "$SUDO_USER" ]; then
    chown -R "$SUDO_USER" "$dest" 2>/dev/null || warn "Unable to hand ${dest} to ${SUDO_USER}."
  fi

  info "Saved agent identity to ${dest}"
  info "  identity_source=${IDENTITY_SOURCE}"
  info "  agent_id=${CFG[AGENT_ID]:-unknown}"
  info "  config_included=${configIncluded}"
  [ "$LEGACY_IDENTITY" = true ] && legacyWarning
  [ "$configIncluded" = true ] && info "config.json holds the agent's access key and secret: store this folder securely."
  return 0
}

typeset -gA MANIFEST
readManifest() {
  local line
  MANIFEST=()
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" == *=* ]] || continue
    MANIFEST[${line%%=*}]="${line#*=}"
  done < "$1"
}

skipInDryRun() {
  if [ "$DRY_RUN" = true ]; then
    info "[dry-run] $1"
    return 0
  fi
  info "$1"
  return 1
}

writeGuidFile() {
  skipInDryRun "Write ${MACHINE_GUID_FILE} (dir 0700, file 0600, root:wheel)." && return 0
  mkdir -p "$MACHINE_GUID_DIRECTORY" || die "Unable to create ${MACHINE_GUID_DIRECTORY}."
  chmod 700 "$MACHINE_GUID_DIRECTORY"
  local tmp="${MACHINE_GUID_FILE}.tmp"
  if printf '%s\n' "$1" > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$MACHINE_GUID_FILE"; then
    isRoot && chown root:wheel "$MACHINE_GUID_DIRECTORY" "$MACHINE_GUID_FILE"
  else
    rm -f "$tmp"
    die "Unable to write ${MACHINE_GUID_FILE}."
  fi
}

writeConfigFile() {
  local configDir="${CONFIG_FILE:h}"
  skipInDryRun "Write ${CONFIG_FILE} (file 0600, root:wheel)." && return 0
  mkdir -p "$configDir" || die "Unable to create ${configDir}."
  local tmp="${CONFIG_FILE}.tmp"
  if cp "$1" "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$CONFIG_FILE"; then
    isRoot && chown root:wheel "$CONFIG_FILE"
  else
    rm -f "$tmp"
    die "Unable to write ${CONFIG_FILE}."
  fi
}

cmdRestore() {
  local from="" withConfig=false force=false
  DRY_RUN=false
  while (( $# )); do
    case "$1" in
      --from) [ -n "$2" ] || usageError "--from needs a backup directory."; from="$2"; shift 2 ;;
      --with-config) withConfig=true; shift ;;
      --force) force=true; shift ;;
      --dry-run) DRY_RUN=true; shift ;;
      -h|--help) usage; exit 0 ;;
      *) usageError "Unknown restore option: $1" ;;
    esac
  done
  [ -n "$from" ] || usageError "restore needs --from DIR."

  # LIONGARD_IDENTITY_ROOT is a test hook; a real restore writes root-owned files.
  if ! isRoot && [ -z "$ROOT_PREFIX" ]; then
    die "restore must run as root. Rerun with sudo."
  fi

  [ -d "$from" ] || die "Backup directory ${from} does not exist."
  local manifest="${from}/manifest.txt" guidCopy="${from}/machine-guid" configCopy="${from}/config.json"
  [ -f "$manifest" ] || die "Missing ${manifest}; not a Liongard identity backup."
  [ -f "$guidCopy" ] || die "Missing ${guidCopy}."
  readManifest "$manifest"

  [ "${MANIFEST[format_version]}" = "$FORMAT_VERSION" ] || die "Unsupported manifest format_version '${MANIFEST[format_version]}' (expected ${FORMAT_VERSION})."
  [ "${MANIFEST[os]}" = "macos" ] || die "Backup is for os '${MANIFEST[os]}', not macos. Use the matching platform's script."

  [ "$(sha256Of "$guidCopy")" = "${MANIFEST[sha256_machine_guid]}" ] || die "Checksum mismatch for ${guidCopy}; the backup is damaged or was edited."

  local configIncluded="${MANIFEST[config_included]}"
  if [ "$configIncluded" = true ]; then
    [ -f "$configCopy" ] || die "Manifest lists config.json but ${configCopy} is missing."
    [ "$(sha256Of "$configCopy")" = "${MANIFEST[sha256_config_json]}" ] || die "Checksum mismatch for ${configCopy}; the backup is damaged or was edited."
  elif [ -f "$configCopy" ]; then
    die "${configCopy} is not listed in the manifest; refusing to trust it."
  fi

  local guid
  guid=$(tr -d '[:space:]' < "$guidCopy")
  isValidMachineGuid "$guid" || die "The saved identity is not a valid MachineGuid."

  local legacy="${MANIFEST[legacy_identity]:-false}"
  local restoreConfig=false
  if [ "$withConfig" = true ]; then
    [ "$configIncluded" = true ] || die "--with-config given but this backup has no config.json (made with --id-only)."
    restoreConfig=true
  elif [ "$legacy" = true ] && [ "$configIncluded" = true ]; then
    info "Backup is flagged legacy_identity=true; restoring config.json too so the agent keeps its record."
    restoreConfig=true
  fi
  if [ "$legacy" = true ] && [ "$configIncluded" != true ]; then
    warn "This backup has a legacy identity and no config.json. The platform record may have no MachineGuid, so the identity alone may not re-attach."
  fi

  local refuse=false current
  if [ -f "$CONFIG_FILE" ]; then
    err "An agent config already exists at ${CONFIG_FILE}."
    refuse=true
  fi
  if [ -f "$MACHINE_GUID_FILE" ]; then
    current=$(tr -d '[:space:]' < "$MACHINE_GUID_FILE" 2>/dev/null)
    if [ "$current" != "$guid" ]; then
      err "A different identity already exists in ${MACHINE_GUID_FILE}."
      refuse=true
    fi
  fi
  if [ "$refuse" = true ]; then
    if [ "$force" = true ]; then
      warn "--force given; overwriting the installed agent's identity."
    else
      err "An installed agent keeps its own identity, and the installer reuses it on reinstall."
      err "Uninstall the agent first, or rerun with --force to overwrite it."
      exit 1
    fi
  fi

  info "Restoring identity from ${from} (agent_id=${MANIFEST[agent_id]:-unknown}, source=${MANIFEST[identity_source]:-unknown})."
  writeGuidFile "$guid"
  [ "$restoreConfig" = true ] && writeConfigFile "$configCopy"

  info ""
  info "Next step: run the normal Liongard install (env-modal script or pkg) with the SAME tenant"
  info "install key and the SAME environment name as the original install."
  [ "$restoreConfig" = true ] && info "The installer finds the restored config, skips registration, and keeps agent ${MANIFEST[agent_id]:-}."
  info "A platform Agent record that was deleted cannot be re-attached; the install then creates a new agent."
  [ "$DRY_RUN" = true ] && info "[dry-run] Nothing was written."
  return 0
}

cmdShow() {
  case "$1" in
    "") ;;
    -h|--help) usage; exit 0 ;;
    *) usageError "show takes no options." ;;
  esac
  requireReadable
  if ! resolveIdentity; then
    if [ ! -f "$MACHINE_GUID_FILE" ] && [ ! -f "$CONFIG_FILE" ]; then
      info "No agent identity or config found."
      ! isRoot && [ -z "$ROOT_PREFIX" ] && info "The identity files are root-only; rerun with sudo to be sure."
      return 0
    fi
    die "Unable to determine the existing agent's identity."
  fi
  info "identity=${IDENTITY}"
  info "identity_source=${IDENTITY_SOURCE}"
  info "legacy_identity=${LEGACY_IDENTITY}"
  if [ -f "$CONFIG_FILE" ]; then
    loadConfigFields "$CONFIG_FILE"
    [ "$CONFIG_PARSED" = true ] || warn "${CONFIG_FILE} is not valid JSON; showing best-effort values."
    local key
    for key in URL AGENT_ID AGENT_NAME AGENT_UID MACHINE_GUID RESPONSE_QUEUE WORK_DIR AGENT_VERSION; do
      info "${key}=${CFG[$key]}"
    done
  else
    info "config=absent"
  fi
  [ "$LEGACY_IDENTITY" = true ] && legacyWarning
  return 0
}

case "$1" in
  backup) shift; cmdBackup "$@" ;;
  restore) shift; cmdRestore "$@" ;;
  show) shift; cmdShow "$@" ;;
  -h|--help|help) usage; exit 0 ;;
  "") usage; exit 2 ;;
  *) usageError "Unknown action: $1" ;;
esac
