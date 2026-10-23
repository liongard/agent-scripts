#!/usr/bin/env bash

set -uo pipefail

if (( BASH_VERSINFO[0] < 4 )); then
  echo "Error: bash 4 or later is required (found ${BASH_VERSION})" >&2
  exit 1
fi

# Test hook: prefixes /opt, /etc and /var/lib so tests never touch the real host.
ROOT="${LIONGARD_IDENTITY_ROOT:-}"
AGENT_DIR="${ROOT}/opt/liongard"
CONFIG_PATH="${AGENT_DIR}/.config"
GUID_DIR="${ROOT}/etc/liongard-agent"
GUID_PATH="${GUID_DIR}/.machine-guid"
LEGACY_ID_PATHS=("${ROOT}/var/lib/dbus/machine-id" "${ROOT}/etc/machine-id")
GUID_RE='^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'
FORMAT_VERSION=1
REQUIRED_CONFIG_KEYS=(URL AGENT_ID AGENT_NAME AGENT_UID ROAR_ACCESS_KEY_ID ROAR_SECRET_ACCESS_KEY RESPONSE_QUEUE WORK_DIR AGENT_VERSION)
SECRET_CONFIG_KEYS=(ROAR_ACCESS_KEY_ID ROAR_SECRET_ACCESS_KEY)

declare -A CFG=()
declare -A MAN=()
HAVE_CONFIG=0
IDENTITY=""
IDENTITY_SOURCE=""
IDENTITY_TIER=""
IDENTITY_PATH=""
PARTIAL_DIR=""

usage() {
  cat <<'EOF'
Usage:
  LGAgentIdentity-Linux.sh backup [--output DIR] [--id-only]
  LGAgentIdentity-Linux.sh restore --from DIR [--with-config] [--force] [--dry-run]
  LGAgentIdentity-Linux.sh show
  LGAgentIdentity-Linux.sh --help

Saves and restores the Liongard Agent identity so a rebuilt or reimaged Linux
host re-attaches to its existing Agent record.

Actions:
  backup
    Resolve the identity in installer order (/etc/liongard-agent/.machine-guid,
    then MACHINE_GUID in /opt/liongard/.config, then the legacy machine-id) and
    save it with a copy of /opt/liongard/.config. Needs sudo to read the 0600 files.

    --output DIR   Existing folder to write the backup into. The script creates
                   liongard-identity-<host>-<UTC time> inside it and refuses to
                   overwrite that folder. Default: the home of the sudo user.
    --id-only      Save only the identity, not the config.

  restore
    Validate a backup, then write /etc/liongard-agent/.machine-guid. Must run as root.

    --from DIR     Backup directory to restore from (required).
    --with-config  Also restore /opt/liongard/.config. The next install then upgrades
                   in place: no registration, same agent ID, same agent credentials.
                   Without it, only the identity is restored and the next install
                   registers again with the same MachineGuid.
    --force        Overwrite an installed config or a different identity file.
    --dry-run      Validate and print the plan. Write nothing.

  show
    Print the identity, its source, and the non-secret config fields. Read-only.

Exit codes: 0 success, 1 error, 2 usage error.
EOF
}

die() {
  echo "Error: $*" >&2
  if [[ -n "$PARTIAL_DIR" ]]; then
    rm -rf -- "$PARTIAL_DIR"
  fi
  exit 1
}

warn() {
  echo "Warning: $*" >&2
}

usage_error() {
  echo "Error: $*" >&2
  echo >&2
  usage >&2
  exit 2
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

sha256_of() {
  sha256sum -- "$1" | cut -d' ' -f1
}

# Mirrors the installer's parser: split on the first '=' only.
load_kv_file() {
  local -n target="$1"
  local path="$2" line key
  target=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"
    [[ -n "$key" ]] || continue
    # shellcheck disable=SC2034
    target["$key"]="${line#*=}"
  done < "$path"
}

# Keeps scheme and host:port so proxy credentials never reach output.
redact_url() {
  local url="$1" scheme="" rest
  [[ -n "$url" ]] || return 0
  rest="$url"
  if [[ "$rest" == *://* ]]; then
    scheme="${rest%%://*}://"
    rest="${rest#*://}"
  fi
  if [[ "$rest" == *@* ]]; then
    printf '%s***@%s' "$scheme" "${rest##*@}"
  else
    printf '%s%s' "$scheme" "$rest"
  fi
}

require_readable() {
  local path
  for path in "$GUID_PATH" "$CONFIG_PATH"; do
    if [[ -e "$path" && ! -r "$path" ]]; then
      die "cannot read $path. The agent identity files are mode 0600 and owned by root. Re-run with sudo."
    fi
  done
}

# Same tier order as resolveMachineGuid in installers/makeself/src/install.ts (Tiers 1-3).
resolve_identity() {
  local value path
  require_readable
  if [[ -f "$CONFIG_PATH" ]]; then
    load_kv_file CFG "$CONFIG_PATH"
    HAVE_CONFIG=1
  fi

  if [[ -f "$GUID_PATH" ]]; then
    value="$(trim "$(<"$GUID_PATH")")"
    if [[ "$value" =~ $GUID_RE ]]; then
      IDENTITY="$value" IDENTITY_SOURCE="guid-file" IDENTITY_TIER=1 IDENTITY_PATH="$GUID_PATH"
      return 0
    fi
    if [[ -n "$value" ]]; then
      warn "ignoring invalid identity in $GUID_PATH (the installer ignores it too)"
    fi
  fi

  (( HAVE_CONFIG )) || return 1

  value="$(trim "${CFG[MACHINE_GUID]:-}")"
  if [[ -n "$value" ]]; then
    IDENTITY="$value" IDENTITY_TIER=2 IDENTITY_PATH="$CONFIG_PATH"
    if [[ "$value" =~ $GUID_RE ]]; then
      IDENTITY_SOURCE="config"
    else
      IDENTITY_SOURCE="config-nonstandard"
      warn "MACHINE_GUID in $CONFIG_PATH is outside the supported character set. It can only be kept by restoring the config (--with-config)."
    fi
    return 0
  fi

  # Legacy machine-id counts only when a config exists, as in the installer.
  for path in "${LEGACY_ID_PATHS[@]}"; do
    [[ -r "$path" ]] || continue
    value="$(trim "$(<"$path")")"
    if [[ "$value" =~ $GUID_RE ]]; then
      IDENTITY="$value" IDENTITY_SOURCE="machine-id" IDENTITY_TIER=3 IDENTITY_PATH="$path"
      return 0
    fi
    if [[ -n "$value" ]]; then
      warn "ignoring unusable machine-id in $path"
    fi
  done
  return 1
}

installer_name() {
  case "$(uname -m)" in
    aarch64|arm64) echo "LiongardAgent-lts-arm64.xz.run" ;;
    *) echo "LiongardAgent-lts-x64.xz.run" ;;
  esac
}

print_legacy_warning() {
  warn "this identity comes from the OS machine-id. Cloned machines share a machine-id, so it may not be unique to this host. If the platform record holds a different MachineGuid, only the config backup (restore --with-config) re-attaches it."
}

backup() {
  local parent="" output id_only=0 owner home include_config=0 created host
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --output)
        [[ $# -ge 2 && -n "$2" ]] || usage_error "--output requires a value"
        parent="$2"
        shift 2
        ;;
      --id-only)
        id_only=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        usage_error "unknown backup option: $1"
        ;;
    esac
  done

  if ! resolve_identity; then
    if (( HAVE_CONFIG )); then
      die "$CONFIG_PATH has no MACHINE_GUID and no usable machine-id exists. The installer cannot upgrade this agent either. Contact Liongard support."
    fi
    die "no Liongard Agent identity found: neither $GUID_PATH nor $CONFIG_PATH exists. If the agent is installed, re-run with sudo (the files are mode 0600, owned by root)."
  fi

  owner="$(id -un)"
  home="${HOME:-}"
  if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    owner="$SUDO_USER"
    home="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
  fi

  created="$(date -u +%Y%m%dT%H%M%SZ)"
  host="$(hostname -s 2>/dev/null || uname -n)"
  host="${host%%.*}"
  if [[ -z "$parent" ]]; then
    [[ -n "$home" && -d "$home" ]] || die "cannot find the home directory for $owner. Pass --output DIR."
    parent="$home"
  fi
  [[ -d "$parent" ]] || die "output folder $parent does not exist. Create it first or pass an existing folder."
  output="${parent%/}/liongard-identity-${host}-${created}"
  if [[ -e "$output" ]]; then
    die "$output already exists. Refusing to overwrite it."
  fi

  umask 077
  mkdir -m 0700 -- "$output" || die "cannot create $output"
  PARTIAL_DIR="$output"

  if (( ! id_only && HAVE_CONFIG )); then
    include_config=1
  fi

  printf '%s\n' "$IDENTITY" > "$output/machine-guid" || die "cannot write $output/machine-guid"
  if (( include_config )); then
    cp -- "$CONFIG_PATH" "$output/config" || die "cannot copy $CONFIG_PATH"
  fi

  {
    echo "format_version=${FORMAT_VERSION}"
    echo "os=linux"
    echo "hostname=${host}"
    echo "created_utc=${created}"
    echo "identity_source=${IDENTITY_SOURCE}"
    echo "identity_tier=${IDENTITY_TIER}"
    echo "agent_id=${CFG[AGENT_ID]:-}"
    echo "agent_name=${CFG[AGENT_NAME]:-}"
    echo "agent_uid=${CFG[AGENT_UID]:-}"
    echo "url=$(redact_url "${CFG[URL]:-}")"
    echo "agent_version=${CFG[AGENT_VERSION]:-}"
    if (( include_config )); then
      echo "config_included=true"
    else
      echo "config_included=false"
    fi
    echo "sha256_machine_guid=$(sha256_of "$output/machine-guid")"
    if (( include_config )); then
      echo "sha256_config=$(sha256_of "$output/config")"
    fi
  } > "$output/manifest.txt" || die "cannot write $output/manifest.txt"

  if ! { chmod 0700 "$output" && chmod 0600 "$output"/*; }; then
    die "cannot set modes on $output"
  fi
  if [[ $EUID -eq 0 && "$owner" != "root" ]]; then
    chown -R -- "$owner:" "$output" || die "cannot give $output to $owner"
  fi
  PARTIAL_DIR=""

  echo "Backup written to $output"
  echo "  identity:        $IDENTITY"
  echo "  identity source: tier $IDENTITY_TIER ($IDENTITY_SOURCE, $IDENTITY_PATH)"
  echo "  agent id:        ${CFG[AGENT_ID]:-unknown}"
  if (( include_config )); then
    echo "  config included: yes. It holds the agent credentials: store this backup securely."
  else
    echo "  config included: no"
  fi
  if [[ "$IDENTITY_SOURCE" == "machine-id" ]]; then
    print_legacy_warning
    if (( ! include_config )); then
      warn "this backup has no config. Back up again without --id-only to keep that option."
    fi
  fi
  if [[ "$IDENTITY_SOURCE" == "config-nonstandard" && $include_config -eq 0 ]]; then
    warn "this identity cannot be restored without the config. Back up again without --id-only."
  fi
}

print_next_steps() {
  local with_config="$1" guid="$2" run url
  run="sudo ./$(installer_name)"
  url="${MAN[url]:-<url>}"
  echo
  if (( with_config )); then
    echo "Next step: run the installer with no options:"
    echo "  $run"
    echo "It finds $CONFIG_PATH and upgrades in place: no registration, same agent ID (${MAN[agent_id]:-unknown}), same credentials."
    echo "It ignores -u/-k/-s on this path, so do not pass them."
    echo "Use installer version ${MAN[agent_version]:-of the backed-up agent} or later. An older installer aborts."
  else
    echo "Next step: run a fresh install. It reads $GUID_PATH and registers with the same MachineGuid:"
    echo "  $run -- -u $url -k <install key> -s <install secret> [-e <environment>]"
    echo "Alternative without restoring the file: pass the identity on a fresh install."
    echo "  $run -- -u $url -k <install key> -s <install secret> [-e <environment>] -g $guid"
    echo "-g is ignored when $GUID_PATH already exists."
    if [[ "${MAN[config_included]:-}" == "true" ]]; then
      echo "If the install creates a new record instead, uninstall (-x) and restore again with --with-config."
    fi
  fi
  echo
  echo "Notes:"
  echo "  - A deleted Agent record cannot be re-attached. The install then creates a new record."
  echo "  - Re-attach needs the same tenant install key (-k/-s) and the same environment (-e) as the original agent."
}

restore() {
  local from="" with_config=0 force=0 dry_run=0 guid current key missing=() write_guid=1 tmp
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from)
        [[ $# -ge 2 && -n "$2" ]] || usage_error "--from requires a value"
        from="$2"
        shift 2
        ;;
      --with-config)
        with_config=1
        shift
        ;;
      --force)
        force=1
        shift
        ;;
      --dry-run)
        dry_run=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        usage_error "unknown restore option: $1"
        ;;
    esac
  done
  [[ -n "$from" ]] || usage_error "restore requires --from DIR"
  [[ $EUID -eq 0 ]] || die "restore must run as root. Re-run with sudo."

  [[ -d "$from" ]] || die "$from is not a directory"
  [[ -f "$from/manifest.txt" ]] || die "$from/manifest.txt is missing"
  [[ -f "$from/machine-guid" ]] || die "$from/machine-guid is missing"
  load_kv_file MAN "$from/manifest.txt"

  [[ "${MAN[format_version]:-}" == "$FORMAT_VERSION" ]] || die "unsupported manifest format_version '${MAN[format_version]:-}' (expected $FORMAT_VERSION)"
  [[ "${MAN[os]:-}" == "linux" ]] || die "this backup is for os '${MAN[os]:-}', not linux"
  [[ "$(sha256_of "$from/machine-guid")" == "${MAN[sha256_machine_guid]:-}" ]] || die "checksum mismatch for $from/machine-guid. The backup is damaged or was edited."

  if [[ "${MAN[config_included]:-}" == "true" ]]; then
    [[ -f "$from/config" ]] || die "$from/config is missing"
    [[ "$(sha256_of "$from/config")" == "${MAN[sha256_config]:-}" ]] || die "checksum mismatch for $from/config. The backup is damaged or was edited."
  elif (( with_config )); then
    die "--with-config was given, but this backup has no config (it was made with --id-only or without an installed agent)"
  fi

  guid="$(<"$from/machine-guid")"
  if [[ ! "$guid" =~ $GUID_RE ]]; then
    if [[ "${MAN[identity_source]:-}" == "config-nonstandard" && $with_config -eq 1 ]]; then
      write_guid=0
      warn "the identity is outside the supported character set. Restoring the config only, as the installer would."
    else
      die "invalid identity in $from/machine-guid. Allowed: letters, digits, '.', '_', '-' (max 128 chars, starts with a letter or digit)."
    fi
  fi

  if (( with_config )); then
    load_kv_file CFG "$from/config"
    for key in "${REQUIRED_CONFIG_KEYS[@]}"; do
      [[ -n "${CFG[$key]:-}" ]] || missing+=("$key")
    done
    if (( ${#missing[@]} )); then
      die "the backed-up config is missing ${missing[*]}. The installer would reject it."
    fi
  fi

  if [[ -e "$CONFIG_PATH" ]]; then
    if (( force )); then
      warn "$CONFIG_PATH exists; continuing because of --force"
    else
      die "an agent is installed ($CONFIG_PATH exists). Uninstall it first (sudo ./$(installer_name) -- -x) or pass --force."
    fi
  fi
  if (( write_guid )) && [[ -f "$GUID_PATH" ]]; then
    current="$(trim "$(<"$GUID_PATH")")"
    if [[ "$current" != "$guid" ]]; then
      if (( force )); then
        warn "replacing the different identity in $GUID_PATH because of --force"
      else
        die "$GUID_PATH holds a different identity ($current). Pass --force to replace it."
      fi
    fi
  fi

  if (( dry_run )); then
    echo "Dry run: backup $from is valid. Nothing was written."
    if (( write_guid )); then
      echo "Would write $GUID_PATH ($guid, mode 0600, dir 0700)"
    fi
    if (( with_config )); then
      echo "Would write $CONFIG_PATH (mode 0600, root:root)"
    elif [[ "${MAN[config_included]:-}" == "true" ]]; then
      echo "Would leave $CONFIG_PATH alone (pass --with-config to restore it)"
    fi
    print_next_steps "$with_config" "$guid"
    return 0
  fi

  umask 077
  if (( write_guid )); then
    if ! { mkdir -p -- "$GUID_DIR" && chmod 0700 "$GUID_DIR"; }; then
      die "cannot create $GUID_DIR"
    fi
    tmp="${GUID_PATH}.tmp"
    if ! { printf '%s\n' "$guid" > "$tmp" && chmod 0600 "$tmp" && chown 0:0 "$tmp" && mv -f -- "$tmp" "$GUID_PATH"; }; then
      rm -f -- "$tmp"
      die "cannot write $GUID_PATH"
    fi
    echo "Restored identity $guid to $GUID_PATH"
  fi

  if (( with_config )); then
    mkdir -p -- "$AGENT_DIR" || die "cannot create $AGENT_DIR"
    tmp="${CONFIG_PATH}.tmp"
    if ! { cp -- "$from/config" "$tmp" && chmod 0600 "$tmp" && chown 0:0 "$tmp" && mv -f -- "$tmp" "$CONFIG_PATH"; }; then
      rm -f -- "$tmp"
      die "cannot write $CONFIG_PATH"
    fi
    echo "Restored agent config to $CONFIG_PATH"
  elif [[ "${MAN[config_included]:-}" == "true" ]]; then
    echo "The backup also holds a config. It was not restored (pass --with-config to restore it)."
  fi

  if [[ "${MAN[identity_source]:-}" == "machine-id" ]]; then
    print_legacy_warning
  fi
  print_next_steps "$with_config" "$guid"
}

show() {
  local key value
  if [[ $# -gt 0 ]]; then
    [[ "$1" == "-h" || "$1" == "--help" ]] && { usage; exit 0; }
    usage_error "show takes no options"
  fi

  if resolve_identity; then
    echo "Identity:        $IDENTITY"
    echo "Identity source: tier $IDENTITY_TIER ($IDENTITY_SOURCE, $IDENTITY_PATH)"
  elif (( HAVE_CONFIG )); then
    echo "Identity:        none usable (the installer cannot upgrade this agent)"
  else
    die "no Liongard Agent identity found: neither $GUID_PATH nor $CONFIG_PATH exists. If the agent is installed, re-run with sudo."
  fi
  if [[ "$IDENTITY_SOURCE" == "machine-id" ]]; then
    print_legacy_warning
  fi

  if (( ! HAVE_CONFIG )); then
    echo "Config:          none ($CONFIG_PATH does not exist)"
    return 0
  fi
  echo "Config:          $CONFIG_PATH"
  for key in URL AGENT_ID AGENT_NAME AGENT_UID MACHINE_GUID RESPONSE_QUEUE WORK_DIR AGENT_VERSION; do
    echo "  $key=${CFG[$key]:-}"
  done
  for key in "${SECRET_CONFIG_KEYS[@]}"; do
    if [[ -n "${CFG[$key]:-}" ]]; then
      value="<set, hidden>"
    else
      value="<missing>"
    fi
    echo "  $key=$value"
  done
  echo "  GLOBAL_AGENT_HTTP_PROXY=$(redact_url "${CFG[GLOBAL_AGENT_HTTP_PROXY]:-}")"
}

if [[ $# -eq 0 ]]; then
  usage >&2
  exit 2
fi

action="$1"
shift
case "$action" in
  backup) backup "$@" ;;
  restore) restore "$@" ;;
  show) show "$@" ;;
  -h|--help|help) usage ;;
  *) usage_error "unknown action: $action" ;;
esac
