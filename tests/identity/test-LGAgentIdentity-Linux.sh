#!/usr/bin/env bash

# Self-contained tests for LGAgentIdentity-Linux.sh. Run as root in a throwaway Linux container.
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../linux" && pwd)/LGAgentIdentity-Linux.sh"
WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT

# Pins the backup timestamp so the refuse-to-overwrite case is deterministic.
mkdir -p "$WORK/bin"
printf '#!/bin/sh\necho 20260101T000000Z\n' > "$WORK/bin/date"
chmod +x "$WORK/bin/date"

GUID="3f2b6c1e-8a4d-4f7e-9b21-0c5d7e8f9a10"
OTHER_GUID="aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
MACHINE_ID="0123456789abcdef0123456789abcdef"
DBUS_ID="fedcba9876543210fedcba9876543210"
SECRET_KEY="AKIASECRETKEYID123"
SECRET_VALUE="sUpErSeCrEtVaLuE456"
PROXY_PASS="pr0xyPassw0rd"

pass=0
fail=0
case_n=0
OUT=""
RC=0

ok() {
  pass=$((pass + 1))
  echo "  ok   - $1"
}

not_ok() {
  fail=$((fail + 1))
  echo "  FAIL - $1"
  while IFS= read -r line; do echo "         | $line"; done <<<"$OUT"
}

check() {
  local desc="$1"
  shift
  if "$@"; then ok "$desc"; else not_ok "$desc"; fi
}

new_root() {
  case_n=$((case_n + 1))
  R="$WORK/root-$case_n"
  mkdir -p "$R"
  echo
  echo "# $1"
}

seed_guid() {
  mkdir -p "$R/etc/liongard-agent"
  chmod 0700 "$R/etc/liongard-agent"
  printf '%s\n' "$1" > "$R/etc/liongard-agent/.machine-guid"
  chmod 0600 "$R/etc/liongard-agent/.machine-guid"
}

seed_config() {
  local machine_guid="$1" proxy="${2:-}"
  mkdir -p "$R/opt/liongard"
  cat > "$R/opt/liongard/.config" <<EOF
URL=us1.app.liongard.com
AGENT_ID=4242
AGENT_NAME=web-01
AGENT_UID=uid-4242
MACHINE_GUID=${machine_guid}
ROAR_ACCESS_KEY_ID=${SECRET_KEY}
ROAR_SECRET_ACCESS_KEY=${SECRET_VALUE}
RESPONSE_QUEUE=https://sqs.example/queue==
WORK_DIR=/opt/liongard
AGENT_VERSION=5.5.0
GLOBAL_AGENT_HTTP_PROXY=${proxy}
EOF
  chmod 0600 "$R/opt/liongard/.config"
}

run() {
  OUT="$(PATH="$WORK/bin:$PATH" LIONGARD_IDENTITY_ROOT="$R" bash "$SCRIPT" "$@" 2>&1)"
  RC=$?
}

rc_is() { [[ "$RC" -eq "$1" ]]; }
out_has() { grep -qF -- "$1" <<<"$OUT"; }
out_lacks() { ! grep -qF -- "$1" <<<"$OUT"; }
man_is() { grep -qxF -- "$2=$3" "$1/manifest.txt"; }
mode_is() { [[ "$(stat -c %a "$1")" == "$2" ]]; }
absent() { [[ ! -e "$1" ]]; }
file_is() { [[ "$(cat "$1")" == "$2" ]]; }
sha_ok() { [[ "$(sha256sum "$1/$2" | cut -d' ' -f1)" == "$(grep "^sha256_$3=" "$1/manifest.txt" | cut -d= -f2)" ]]; }
no_secrets_in() { ! grep -qE -- "$SECRET_KEY|$SECRET_VALUE|$PROXY_PASS" "$1"; }
empty_dir() { [[ -d "$1" && -z "$(ls -A "$1")" ]]; }

# Runs backup into parent $1 and sets B to the folder it created.
backup_into() {
  local parent="$1"
  shift
  mkdir -p "$parent"
  run backup --output "$parent" "$@"
  B="$(find "$parent" -mindepth 1 -maxdepth 1 -name "liongard-identity-*" | head -n1)"
}

make_backup() {
  # Builds a valid backup and sets $B from a tier-1 host with a config.
  local src="$WORK/src-$case_n"
  mkdir -p "$src"
  R_SAVED="$R"
  R="$src"
  seed_guid "$GUID"
  seed_config "$GUID"
  backup_into "$WORK/backup-$case_n" "$@"
  R="$R_SAVED"
}

restamp_sha() {
  local sum
  sum="$(sha256sum "$1/$2" | cut -d' ' -f1)"
  sed -i "s/^sha256_$3=.*/sha256_$3=$sum/" "$1/manifest.txt"
}

[[ $EUID -eq 0 ]] || { echo "Run these tests as root inside a disposable container." >&2; exit 1; }

new_root "usage"
run
check "no args exits 2" rc_is 2
check "no args prints usage" out_has "Usage:"
run --help
check "--help exits 0" rc_is 0
run bogus
check "unknown action exits 2" rc_is 2
run restore
check "restore without --from exits 2" rc_is 2
run backup --nope
check "unknown option exits 2" rc_is 2

new_root "tier 1 backup (guid file + config)"
seed_guid "$GUID"
seed_config "$OTHER_GUID"
backup_into "$WORK/b-tier1"
check "exit 0" rc_is 0
check "identity is the guid file value" file_is "$B/machine-guid" "$GUID"
check "manifest identity_source=guid-file" man_is "$B" identity_source guid-file
check "manifest os=linux" man_is "$B" os linux
check "manifest format_version=1" man_is "$B" format_version 1
check "manifest agent_id" man_is "$B" agent_id 4242
check "manifest config_included=true" man_is "$B" config_included true
check "config copied verbatim" cmp -s "$R/opt/liongard/.config" "$B/config"
check "sha256 machine-guid matches" sha_ok "$B" machine-guid machine_guid
check "sha256 config matches" sha_ok "$B" config config
check "dir mode 700" mode_is "$B" 700
check "machine-guid mode 600" mode_is "$B/machine-guid" 600
check "config mode 600" mode_is "$B/config" 600
check "manifest mode 600" mode_is "$B/manifest.txt" 600
check "manifest has no secrets" no_secrets_in "$B/manifest.txt"
check "stdout has no secrets" out_lacks "$SECRET_VALUE"
run backup --output "$WORK/b-tier1"
check "existing output dir refused" rc_is 1
check "refusal names the dir" out_has "already exists"

new_root "--output pointing at a missing folder"
seed_guid "$GUID"
run backup --output "$WORK/no-such-dir"
check "exit 1" rc_is 1
check "says the folder does not exist" out_has "does not exist"
check "folder not created" absent "$WORK/no-such-dir"

new_root "invalid tier 1 file is ignored"
seed_guid "bad guid!"
seed_config "$GUID"
backup_into "$WORK/b-badtier1"
check "exit 0" rc_is 0
check "falls back to config identity" file_is "$B/machine-guid" "$GUID"
check "warns about invalid file" out_has "ignoring invalid identity"

new_root "tier 2 backup (config MACHINE_GUID)"
seed_config "$GUID"
backup_into "$WORK/b-tier2"
check "exit 0" rc_is 0
check "identity from config" file_is "$B/machine-guid" "$GUID"
check "manifest identity_source=config" man_is "$B" identity_source config
check "no legacy warning" out_lacks "machine-id"

new_root "tier 3 backup (legacy machine-id)"
seed_config ""
mkdir -p "$R/etc" "$R/var/lib/dbus"
echo "$MACHINE_ID" > "$R/etc/machine-id"
echo "$DBUS_ID" > "$R/var/lib/dbus/machine-id"
backup_into "$WORK/b-tier3"
check "exit 0" rc_is 0
check "dbus machine-id wins over /etc/machine-id" file_is "$B/machine-guid" "$DBUS_ID"
check "manifest identity_source=machine-id" man_is "$B" identity_source machine-id
check "legacy clone warning printed" out_has "Cloned machines share a machine-id"
rm "$R/var/lib/dbus/machine-id"
backup_into "$WORK/b-tier3b"
check "falls back to /etc/machine-id" file_is "$B/machine-guid" "$MACHINE_ID"

new_root "machine-id without config is not an identity"
mkdir -p "$R/etc"
echo "$MACHINE_ID" > "$R/etc/machine-id"
backup_into "$WORK/b-noconfig"
check "exit 1" rc_is 1
check "no backup dir left behind" empty_dir "$WORK/b-noconfig"

new_root "--id-only"
seed_guid "$GUID"
seed_config "$GUID"
backup_into "$WORK/b-idonly" --id-only
check "exit 0" rc_is 0
check "no config file" absent "$B/config"
check "manifest config_included=false" man_is "$B" config_included false
check "no sha256_config line" bash -c "! grep -q '^sha256_config=' '$B/manifest.txt'"

new_root "tier 1 only, no config"
seed_guid "$GUID"
backup_into "$WORK/b-guidonly"
check "exit 0" rc_is 0
check "manifest config_included=false" man_is "$B" config_included false

new_root "proxy credentials never printed"
seed_guid "$GUID"
seed_config "$GUID" "http://proxyuser:${PROXY_PASS}@proxy.local:3128"
backup_into "$WORK/b-proxy"
check "backup exit 0" rc_is 0
check "backup output lacks proxy password" out_lacks "$PROXY_PASS"
check "manifest lacks secrets" no_secrets_in "$B/manifest.txt"
run show
check "show exit 0" rc_is 0
check "show lacks proxy password" out_lacks "$PROXY_PASS"
check "show lacks proxy user" out_lacks "proxyuser"
check "show lacks ROAR key id" out_lacks "$SECRET_KEY"
check "show lacks ROAR secret" out_lacks "$SECRET_VALUE"
check "show keeps proxy host" out_has "http://***@proxy.local:3128"
check "show reports tier 1" out_has "tier 1 (guid-file"
check "show prints agent id" out_has "AGENT_ID=4242"

new_root "no identity and no config"
backup_into "$WORK/b-none"
check "exit 1" rc_is 1
check "message says root is needed" out_has "sudo"
check "no backup dir created" empty_dir "$WORK/b-none"
run show
check "show exit 1" rc_is 1

new_root "default output dir in HOME"
seed_guid "$GUID"
mkdir -p "$WORK/home"
OUT="$(HOME="$WORK/home" LIONGARD_IDENTITY_ROOT="$R" bash "$SCRIPT" backup 2>&1)"
RC=$?
check "exit 0" rc_is 0
check "dir named liongard-identity-<host>-<UTC>" bash -c "ls -d '$WORK'/home/liongard-identity-*-[0-9]*T[0-9]*Z >/dev/null"

new_root "sudo user owns the backup"
seed_guid "$GUID"
mkdir -p "$WORK/b-sudo"
OUT="$(SUDO_USER=nobody LIONGARD_IDENTITY_ROOT="$R" bash "$SCRIPT" backup --output "$WORK/b-sudo" 2>&1)"
RC=$?
B="$(find "$WORK/b-sudo" -mindepth 1 -maxdepth 1 -name "liongard-identity-*")"
check "exit 0" rc_is 0
check "dir owned by nobody" bash -c "[[ \$(stat -c %U '$B') == nobody ]]"
check "files owned by nobody" bash -c "[[ \$(stat -c %U '$B/machine-guid') == nobody ]]"

if command -v setpriv >/dev/null; then
  new_root "non-root access"
  seed_guid "$GUID"
  seed_config "$GUID"
  chmod 0755 "$WORK"
  mkdir -p "$WORK/b-nonroot"
  chmod 0777 "$WORK/b-nonroot"
  OUT="$(LIONGARD_IDENTITY_ROOT="$R" setpriv --reuid=65534 --regid=65534 --clear-groups bash "$SCRIPT" backup --output "$WORK/b-nonroot" 2>&1)"
  RC=$?
  check "non-root backup of 0600 config exits 1" rc_is 1
  check "non-root backup says the files need root" out_has "mode 0600 and owned by root"
  rm -rf "$R/opt"
  OUT="$(LIONGARD_IDENTITY_ROOT="$R" setpriv --reuid=65534 --regid=65534 --clear-groups bash "$SCRIPT" backup --output "$WORK/b-nonroot" 2>&1)"
  RC=$?
  check "non-root backup behind 0700 dir exits 1" rc_is 1
  check "non-root backup says sudo" out_has "re-run with sudo"
  make_backup
  OUT="$(LIONGARD_IDENTITY_ROOT="$R" setpriv --reuid=65534 --regid=65534 --clear-groups bash "$SCRIPT" restore --from "$B" 2>&1)"
  RC=$?
  check "non-root restore exits 1" rc_is 1
  check "non-root restore says root" out_has "must run as root"
fi

new_root "restore success (identity only)"
make_backup
run restore --from "$B"
check "exit 0" rc_is 0
check "guid file written" file_is "$R/etc/liongard-agent/.machine-guid" "$GUID"
check "guid file mode 600" mode_is "$R/etc/liongard-agent/.machine-guid" 600
check "guid dir mode 700" mode_is "$R/etc/liongard-agent" 700
check "guid file owned by root" bash -c "[[ \$(stat -c %u:%g '$R/etc/liongard-agent/.machine-guid') == 0:0 ]]"
check "no temp file left" absent "$R/etc/liongard-agent/.machine-guid.tmp"
check "config not restored by default" absent "$R/opt/liongard/.config"
check "next step is a fresh install" out_has "-u us1.app.liongard.com -k <install key>"
check "prints the -g alternative" out_has "-g $GUID"
check "warns about deleted records" out_has "deleted Agent record cannot be re-attached"
check "warns tenant key and -e must match" out_has "same environment (-e)"
run restore --from "$B"
check "re-running with the same identity succeeds" rc_is 0

new_root "restore --with-config"
make_backup
run restore --from "$B" --with-config
check "exit 0" rc_is 0
check "config restored verbatim" cmp -s "$B/config" "$R/opt/liongard/.config"
check "config mode 600" mode_is "$R/opt/liongard/.config" 600
check "config owned by root" bash -c "[[ \$(stat -c %u:%g '$R/opt/liongard/.config') == 0:0 ]]"
check "next step is a no-option install" out_has "run the installer with no options"
check "says not to pass -u/-k/-s" out_has "do not pass them"
check "output lacks secrets" out_lacks "$SECRET_VALUE"

new_root "restore --with-config on an id-only backup"
make_backup --id-only
run restore --from "$B" --with-config
check "exit 1" rc_is 1
check "nothing written" absent "$R/etc/liongard-agent"

new_root "restore --with-config with an incomplete config"
make_backup
sed -i '/^ROAR_SECRET_ACCESS_KEY=/d' "$B/config"
restamp_sha "$B" config config
run restore --from "$B" --with-config
check "exit 1" rc_is 1
check "names the missing key" out_has "ROAR_SECRET_ACCESS_KEY"
check "nothing written" absent "$R/etc/liongard-agent"

new_root "restore refused with an installed agent"
make_backup
seed_config "$OTHER_GUID"
cp "$R/opt/liongard/.config" "$WORK/config-before"
run restore --from "$B" --with-config
check "exit 1" rc_is 1
check "says an agent is installed" out_has "an agent is installed"
check "config untouched" cmp -s "$WORK/config-before" "$R/opt/liongard/.config"
check "guid file not written" absent "$R/etc/liongard-agent/.machine-guid"
run restore --from "$B" --with-config --force
check "--force exits 0" rc_is 0
check "--force overwrote config" cmp -s "$B/config" "$R/opt/liongard/.config"
check "--force wrote guid file" file_is "$R/etc/liongard-agent/.machine-guid" "$GUID"

new_root "restore refused with a different identity file"
make_backup
seed_guid "$OTHER_GUID"
run restore --from "$B"
check "exit 1" rc_is 1
check "says the identity differs" out_has "holds a different identity"
check "guid file untouched" file_is "$R/etc/liongard-agent/.machine-guid" "$OTHER_GUID"
run restore --from "$B" --force
check "--force exits 0" rc_is 0
check "--force replaced guid file" file_is "$R/etc/liongard-agent/.machine-guid" "$GUID"

new_root "--dry-run writes nothing"
make_backup
run restore --from "$B" --with-config --dry-run
check "exit 0" rc_is 0
check "says nothing was written" out_has "Nothing was written"
check "no guid dir" absent "$R/etc/liongard-agent"
check "no config" absent "$R/opt/liongard"

new_root "checksum tamper"
make_backup
echo "$OTHER_GUID" > "$B/machine-guid"
run restore --from "$B"
check "machine-guid tamper exits 1" rc_is 1
check "reports checksum mismatch" out_has "checksum mismatch"
check "nothing written" absent "$R/etc/liongard-agent"
make_backup
echo "EXTRA=1" >> "$B/config"
run restore --from "$B"
check "config tamper exits 1 even without --with-config" rc_is 1
check "nothing written" absent "$R/etc/liongard-agent"

new_root "wrong os in manifest"
make_backup
sed -i 's/^os=linux$/os=macos/' "$B/manifest.txt"
run restore --from "$B"
check "exit 1" rc_is 1
check "names the os" out_has "macos"
check "nothing written" absent "$R/etc/liongard-agent"

new_root "wrong format_version"
make_backup
sed -i 's/^format_version=1$/format_version=2/' "$B/manifest.txt"
run restore --from "$B"
check "exit 1" rc_is 1

new_root "invalid GUID"
make_backup
printf '%s\n' "bad guid!" > "$B/machine-guid"
restamp_sha "$B" machine-guid machine_guid
run restore --from "$B"
check "exit 1" rc_is 1
check "reports invalid identity" out_has "invalid identity"
check "nothing written" absent "$R/etc/liongard-agent"
printf '%s\n' "-leading-dash" > "$B/machine-guid"
restamp_sha "$B" machine-guid machine_guid
run restore --from "$B"
check "leading dash rejected" rc_is 1

new_root "missing manifest"
make_backup
rm "$B/manifest.txt"
run restore --from "$B"
check "exit 1" rc_is 1

echo
echo "passed: $pass  failed: $fail"
[[ $fail -eq 0 ]]
