#!/usr/bin/env bash
# Checks the pre-removal identity backup: identifiers collected, no secret written, LGAgentIdentity accepts it.
# Usage: bash tests/test-identity-backup.sh linux   (needs sha256sum)  |  bash tests/test-identity-backup.sh macos

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/lg-identity-backup.XXXXXX")" || exit 1
trap 'rm -rf "$WORK"' EXIT
SECRET="FAKE-SECRET-DO-NOT-WRITE"
GUID="3f2b6c1e-8a4d-4f7e-9b21-0c5d7e8f9a10"
LEGACY="0123456789abcdef0123456789abcdef"
pass=0
fail=0

check() {
  if eval "$2"; then pass=$((pass + 1)); echo "ok    $1"; else fail=$((fail + 1)); echo "FAIL  $1"; sed 's/^/        | /' "$WORK/out" | tail -n 15; fi
}

# Usage: load <script> <agent block name>. Sources the common block and the agent block of a script.
load() {
  sed -n "/^# BEGIN SHARED BLOCK: Liongard shell common functions\$/,/^# END SHARED BLOCK: Liongard shell common functions\$/p;/^# BEGIN SHARED BLOCK: $2\$/,/^# END SHARED BLOCK: $2\$/p" "$1" > "$WORK/blocks.sh"
  # shellcheck disable=SC1090,SC1091
  . "$WORK/blocks.sh"
}

mode() {
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"
}

run_linux() {
  mkdir -p "$WORK/opt" "$WORK/etc/liongard-agent" "$WORK/log"
  printf 'URL=us1.app.liongard.com\nAGENT_ID=4242\nAGENT_NAME=host1\nAGENT_UID=uid-1\nMACHINE_GUID=%s\nROAR_ACCESS_KEY_ID=AKIAFAKE\nROAR_SECRET_ACCESS_KEY=%s\nAGENT_VERSION=5.5.0\n' "$GUID" "$SECRET" > "$WORK/opt/.config"
  printf '%s\n' "$GUID" > "$WORK/etc/liongard-agent/.machine-guid"
  printf '%s\n' "$LEGACY" > "$WORK/etc/machine-id"
  load "$ROOT/linux/LGAgentUninstall-Linux-Simple.sh" "Liongard Linux agent functions"
  LG_AGENT_CONFIG="$WORK/opt/.config"
  LG_GUID_DIR="$WORK/etc/liongard-agent"
  LG_GUID_FILE="$WORK/etc/liongard-agent/.machine-guid"
  LG_MACHINE_ID_FILES="$WORK/etc/machine-id"
  lg_collect_identity 2> "$WORK/out"
  check "AgentID read from the config" '[ "$LG_ID_AGENT_ID" = 4242 ]'
  check "agent identifier listed once (file and config agree)" '[ "$(lg_values "$LG_ID_AGENT")" = "$GUID" ]'
  check "machine-id is an OS identifier" '[ "$(lg_values "$LG_ID_OS")" = "$LEGACY" ]'
  ( lg_save_identity_backup "$WORK/log" ) 2>> "$WORK/out"
  dest="$(ls -d "$WORK"/log/liongard-identity-* 2>/dev/null | head -1)"
  check "backup folder written" '[ -n "$dest" ] && [ -f "$dest/machine-guid" ] && [ -f "$dest/manifest.txt" ]'
  check "backup folder is 0700 and files 0600" '[ "$(mode "$dest")" = 700 ] && [ "$(mode "$dest/manifest.txt")" = 600 ]'
  check "no secret in the backup" '! grep -rq -e "$SECRET" -e AKIAFAKE "$dest"'
  check "manifest has the AgentID" 'grep -qx "agent_id=4242" "$dest/manifest.txt"'
  out="$(bash "$ROOT/linux/LGAgentIdentity-Linux.sh" restore --from "$dest" --dry-run 2>&1)"
  printf '%s\n' "$out" >> "$WORK/out"
  check "LGAgentIdentity-Linux.sh accepts the backup" 'printf "%s" "$out" | grep -q "is valid"'

  rm -f "$WORK/etc/liongard-agent/.machine-guid"
  grep -v '^MACHINE_GUID=' "$WORK/opt/.config" > "$WORK/opt/.config.new" && mv "$WORK/opt/.config.new" "$WORK/opt/.config"
  lg_collect_identity 2>> "$WORK/out"
  check "with no GUID, the machine-id is saved as the identity (tier 3)" '[ "$LG_ID_VALUE" = "$LEGACY" ] && [ "$LG_ID_TIER" = 3 ]'

  printf 'AGENT_ID=4242\nMACHINE_GUID=%s\n' "$GUID" > "$WORK/opt/.config"
  lg_collect_identity 2>> "$WORK/out"
  ( lg_seed_identity ) 2>> "$WORK/out"
  check "clean install seeds a config-only identity into the identity file" 'grep -qx "$GUID" "$LG_GUID_FILE" && [ "$(mode "$LG_GUID_FILE")" = 600 ]'
}

run_macos() {
  mkdir -p "$WORK/lib" "$WORK/etc" "$WORK/log" "$WORK/bin" "$WORK/restore-root"
  printf '{\n"URL":"us1.app.liongard.com",\n"AGENT_ID":"4242",\n"AGENT_NAME":"mac1",\n"MACHINE_GUID":"%s",\n"ROAR_ACCESS_KEY_ID":"AKIAFAKE",\n"ROAR_SECRET_ACCESS_KEY":"%s",\n"AGENT_VERSION":"5.5.0"\n}\n' "$GUID" "$SECRET" > "$WORK/lib/config.json"
  printf '%s\n' "$GUID" > "$WORK/etc/machine-guid"
  printf '#!/bin/sh\necho "  | \\"IOPlatformUUID\\" = \\"A1B2C3D4-E5F6-4711-8899-AABBCCDDEEFF\\""\n' > "$WORK/bin/ioreg"
  chmod +x "$WORK/bin/ioreg"
  PATH="$WORK/bin:$PATH"
  load "$ROOT/macos/LGAgentUninstall-macOS-Simple.sh" "Liongard macOS agent functions"
  LG_AGENT_CONFIG="$WORK/lib/config.json"
  LG_GUID_FILE="$WORK/etc/machine-guid"
  lg_collect_identity > "$WORK/out" 2>&1
  check "AgentID read from config.json" '[ "$LG_ID_AGENT_ID" = 4242 ]'
  check "agent identifier listed once" '[ "$(lg_values "$LG_ID_AGENT")" = "$GUID" ]'
  check "IOPlatformUUID is an OS identifier" '[ "$(lg_values "$LG_ID_OS")" = A1B2C3D4-E5F6-4711-8899-AABBCCDDEEFF ]'
  ( lg_save_identity_backup "$WORK/log" ) >> "$WORK/out" 2>&1
  dest="$(ls -d "$WORK"/log/liongard-identity-* 2>/dev/null | head -1)"
  check "backup folder written" '[ -n "$dest" ] && [ -f "$dest/machine-guid" ] && [ -f "$dest/manifest.txt" ]'
  check "backup folder is 0700 and files 0600" '[ "$(mode "$dest")" = 700 ] && [ "$(mode "$dest/manifest.txt")" = 600 ]'
  check "no secret in the backup" '! grep -rq -e "$SECRET" -e AKIAFAKE "$dest"'
  if command -v zsh >/dev/null 2>&1
  then
    out="$(LIONGARD_IDENTITY_ROOT="$WORK/restore-root" zsh "$ROOT/macos/LGAgentIdentity-macOS.sh" restore --from "$dest" --dry-run 2>&1)"
    printf '%s\n' "$out" >> "$WORK/out"
    check "LGAgentIdentity-macOS.sh accepts the backup" 'printf "%s" "$out" | grep -q "Nothing was written"'
  else
    echo "skip  LGAgentIdentity-macOS.sh restore check: zsh is not installed"
  fi
}

case "$1" in
  linux) run_linux ;;
  macos) run_macos ;;
  *) echo "Usage: $0 linux|macos" >&2; exit 2 ;;
esac
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
