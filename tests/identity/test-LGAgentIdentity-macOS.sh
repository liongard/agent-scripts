#!/bin/zsh

# Runs LGAgentIdentity-macOS.sh against throwaway trees via LIONGARD_IDENTITY_ROOT; never touches the real agent.

SCRIPT="${0:A:h:h:h}/macos/LGAgentIdentity-macOS.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/liongard-identity-test.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT
unset SUDO_USER

PASS=0 FAIL=0
GUID="3f2b6c1e-9a4d-4c5e-8f00-1234567890ab"
HWUUID="A1B2C3D4-E5F6-4711-8899-AABBCCDDEEFF"
SECRET_ID="AKIASECRETKEYID0001"
SECRET="s3cr3tV4lue/ShouldNeverPrint"

realStamp() { stat -f '%m' /Library/Liongard/.config.json 2>/dev/null || print absent; }
REAL_BEFORE=$(realStamp)

newCase() {
  CASE="$WORK/case$(( ++CASE_N ))"
  ROOT="$CASE/root"
  mkdir -p "$ROOT" "$CASE/home" "$CASE/out"
}

# Every invocation pins LIONGARD_IDENTITY_ROOT to the case tree.
run() {
  [[ "$ROOT" == "$WORK"/* ]] || { print "refusing to run outside the temp tree"; exit 1; }
  OUT=$(env LIONGARD_IDENTITY_ROOT="$ROOT" HOME="$CASE/home" LIONGARD_IDENTITY_IOREG_UUID="$HWUUID" "$@" 2>&1)
  RC=$?
}
li() { run "$SCRIPT" "$@"; }

ok() { (( ++PASS )); print "ok   - $1"; }
nok() { (( ++FAIL )); print "FAIL - $1"; print -r -- "$OUT" | sed 's/^/       /'; }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else nok "$name"; fi; }
has() { [[ "$OUT" == *"$1"* ]]; }
lacks() { [[ "$OUT" != *"$1"* ]]; }
rcIs() { [ "$RC" -eq "$1" ]; }
modeOf() { stat -f '%Lp' "$1"; }

writeGuid() { mkdir -p "$ROOT/etc/liongard-agent"; print -r -- "$1" > "$ROOT/etc/liongard-agent/.machine-guid"; }
writeConfig() {
  mkdir -p "$ROOT/Library/Liongard"
  local guidLine=""
  [ -n "$1" ] && guidLine="\"MACHINE_GUID\":\"$1\","
  cat > "$ROOT/Library/Liongard/.config.json" <<EOF
{
"URL":"us1.app.liongard.com",
"AGENT_ID":"4242",
"AGENT_NAME":"Mark's Mac",
"AGENT_UID":"uid-4242",
${guidLine}
"ROAR_ACCESS_KEY_ID":"${SECRET_ID}",
"ROAR_SECRET_ACCESS_KEY":"${SECRET}",
"RESPONSE_QUEUE":"queue-4242",
"WORK_DIR":"/Library/Liongard",
"AGENT_VERSION":"5.4.5"
}
EOF
  chmod 600 "$ROOT/Library/Liongard/.config.json"
}
backupDir() { print -r -- "$CASE"/out/liongard-identity-*(N[1]); }
manifestHas() { grep -qx -- "$1" "$(backupDir)/manifest.txt"; }
noSecrets() { lacks "$SECRET" && lacks "$SECRET_ID" && ! grep -q -e "$SECRET" -e "$SECRET_ID" "$(backupDir)/manifest.txt"; }

print "# usage"
newCase
li; check "no args prints usage, exit 2" eval 'rcIs 2 && has "Usage:"'
li --help; check "--help exits 0" eval 'rcIs 0 && has "Config restore rule"'
li bogus; check "unknown action exits 2" rcIs 2
li restore; check "restore without --from exits 2" rcIs 2
li backup --nope; check "unknown backup option exits 2" rcIs 2

print "# backup tier 1 (identity file with whitespace)"
newCase
writeGuid "  $GUID  "; writeConfig "$GUID"
li backup --output "$CASE/out"
D=$(backupDir)
check "tier1 backup exits 0" rcIs 0
check "tier1 source recorded" manifestHas "identity_source=tier1-machine-guid-file"
check "machine-guid is trimmed GUID" eval '[ "$(cat "$D/machine-guid")" = "$GUID" ]'
check "config.json copied" eval '[ -f "$D/config.json" ] && manifestHas config_included=true'
check "manifest fields" eval 'manifestHas format_version=1 && manifestHas os=macos && manifestHas agent_id=4242 && manifestHas "agent_name=Mark'"'"'s Mac" && manifestHas agent_uid=uid-4242 && manifestHas url=us1.app.liongard.com && manifestHas agent_version=5.4.5'
check "sha256 values match" eval 'manifestHas "sha256_machine_guid=$(shasum -a 256 "$D/machine-guid" | cut -d" " -f1)" && manifestHas "sha256_config_json=$(shasum -a 256 "$D/config.json" | cut -d" " -f1)"'
check "dir 0700, files 0600" eval '[ "$(modeOf "$D")" = 700 ] && [ "$(modeOf "$D/machine-guid")" = 600 ] && [ "$(modeOf "$D/config.json")" = 600 ] && [ "$(modeOf "$D/manifest.txt")" = 600 ]'
check "no secrets in output or manifest" noSecrets
check "no legacy warning" lacks "may have no MachineGuid"
TIER1_BACKUP="$D"

print "# backup default output and no-overwrite"
li backup
check "default output lands in HOME" eval 'rcIs 0 && [ -n "$(print -r -- "$CASE"/home/liongard-identity-*(N))" ]'
# Pre-create the next few seconds' names so the clock cannot tick past the collision.
NOW=$(date -u +%s)
for s in {0..5}; do mkdir -p "$CASE/out2/liongard-identity-$(hostname -s)-$(date -u -r $(( NOW + s )) +%Y%m%dT%H%M%SZ)"; done
li backup --output "$CASE/out2"
check "existing backup dir is refused" eval 'rcIs 1 && has "refusing to overwrite"'
li backup --output "$CASE/missing"
check "missing --output dir is an error" eval 'rcIs 1 && has "does not exist"'

print "# backup tier 2"
newCase
writeConfig "$GUID"
li backup --output "$CASE/out"
check "tier2 source recorded" eval 'rcIs 0 && manifestHas identity_source=tier2-config-machine-guid && manifestHas legacy_identity=false'
check "tier2 GUID saved" eval '[ "$(cat "$(backupDir)/machine-guid")" = "$GUID" ]'

print "# backup tier 3 (legacy, invalid MACHINE_GUID, invalid tier-1 file)"
newCase
writeGuid "bad guid!"; writeConfig "-not valid"
li backup --output "$CASE/out"
check "tier3 source recorded" eval 'rcIs 0 && manifestHas identity_source=tier3-ioplatformuuid && manifestHas legacy_identity=true'
check "tier3 saves hardware UUID" eval '[ "$(cat "$(backupDir)/machine-guid")" = "$HWUUID" ]'
check "legacy warning printed" has "may have no MachineGuid"
check "invalid tier-1 and config values reported" eval 'has "Ignoring invalid identity" && has "Ignoring invalid MACHINE_GUID"'
LEGACY_BACKUP=$(backupDir)

print "# legacy warning with tier 1 when config has no MACHINE_GUID"
newCase
writeGuid "$GUID"; writeConfig ""
li backup --output "$CASE/out"
check "tier1 + config without MACHINE_GUID warns" eval 'rcIs 0 && has "may have no MachineGuid" && manifestHas legacy_identity=true'

print "# --id-only"
newCase
writeConfig ""
li backup --output "$CASE/out" --id-only
check "--id-only skips config" eval 'rcIs 0 && [ ! -e "$(backupDir)/config.json" ] && manifestHas config_included=false'
check "--id-only still prints legacy warning" has "may have no MachineGuid"
ID_ONLY_LEGACY_BACKUP=$(backupDir)

print "# tier 3 with no hardware UUID"
newCase
writeConfig ""
OUT=$(env LIONGARD_IDENTITY_ROOT="$ROOT" HOME="$CASE/home" LIONGARD_IDENTITY_IOREG_UUID="" "$SCRIPT" backup --output "$CASE/out" 2>&1); RC=$?
check "no usable identity is an error" eval 'rcIs 1 && has "Unable to determine"'

print "# no identity and no config"
newCase
li backup --output "$CASE/out"
check "nothing to back up exits 1" eval 'rcIs 1 && has "Nothing to back up"'

print "# unreadable config (non-root)"
newCase
writeConfig "$GUID"; chmod 000 "$ROOT/Library/Liongard/.config.json"
li backup --output "$CASE/out"
check "unreadable config asks for sudo" eval 'rcIs 1 && has "rerun with sudo"'
chmod 600 "$ROOT/Library/Liongard/.config.json"

print "# invalid JSON config"
newCase
writeGuid "$GUID"; mkdir -p "$ROOT/Library/Liongard"; print '{"AGENT_ID":"77", broken' > "$ROOT/Library/Liongard/.config.json"
li backup --output "$CASE/out"
check "invalid JSON still backed up with warning" eval 'rcIs 0 && has "not valid JSON" && [ -f "$(backupDir)/config.json" ]'

print "# show"
newCase
writeGuid "$GUID"; writeConfig "$GUID"
li show
check "show prints identity and fields" eval 'rcIs 0 && has "identity=$GUID" && has "identity_source=tier1-machine-guid-file" && has "AGENT_ID=4242" && has "AGENT_NAME=Mark'"'"'s Mac"'
check "show hides secrets" eval 'lacks "$SECRET" && lacks "$SECRET_ID" && lacks ROAR_'
newCase
li show
check "show on empty tree" eval 'rcIs 0 && has "No agent identity"'

print "# restore success (non-legacy, identity only)"
newCase
li restore --from "$TIER1_BACKUP"
check "restore exits 0" rcIs 0
check "identity file written" eval '[ "$(cat "$ROOT/etc/liongard-agent/.machine-guid")" = "$GUID" ]'
check "installer-matching modes" eval '[ "$(modeOf "$ROOT/etc/liongard-agent")" = 700 ] && [ "$(modeOf "$ROOT/etc/liongard-agent/.machine-guid")" = 600 ]'
check "config not restored by default" eval '[ ! -e "$ROOT/Library/Liongard/.config.json" ]'
check "next step printed" eval 'has "SAME tenant" && has "SAME environment name" && has "deleted cannot be re-attached"'
check "no temp file left" eval '[ ! -e "$ROOT/etc/liongard-agent/.machine-guid.tmp" ]'
li restore --from "$TIER1_BACKUP"
check "re-restore of the same identity is allowed" rcIs 0

print "# restore --with-config"
newCase
li restore --from "$TIER1_BACKUP" --with-config
check "--with-config writes config 0600" eval 'rcIs 0 && cmp -s "$ROOT/Library/Liongard/.config.json" "$TIER1_BACKUP/config.json" && [ "$(modeOf "$ROOT/Library/Liongard/.config.json")" = 600 ]'
check "--with-config reports registration skip" has "skips registration"

print "# restore legacy backup restores config automatically"
newCase
li restore --from "$LEGACY_BACKUP"
check "legacy auto-restores config" eval 'rcIs 0 && [ -f "$ROOT/Library/Liongard/.config.json" ] && [ "$(cat "$ROOT/etc/liongard-agent/.machine-guid")" = "$HWUUID" ]'
newCase
li restore --from "$ID_ONLY_LEGACY_BACKUP"
check "legacy --id-only restore warns" eval 'rcIs 0 && has "identity alone may not re-attach"'
li restore --from "$ID_ONLY_LEGACY_BACKUP" --with-config
check "--with-config on --id-only backup fails" eval 'rcIs 1 && has "no config.json"'

print "# restore refused with an installed agent, then --force"
newCase
writeConfig "$GUID"
li restore --from "$TIER1_BACKUP"
check "existing config refuses" eval 'rcIs 1 && has "keeps its own identity" && [ ! -e "$ROOT/etc/liongard-agent/.machine-guid" ]'
newCase
writeGuid "11111111-2222-3333-4444-555555555555"
li restore --from "$TIER1_BACKUP"
check "different identity refuses" eval 'rcIs 1 && has "different identity" && grep -q 11111111 "$ROOT/etc/liongard-agent/.machine-guid"'
li restore --from "$TIER1_BACKUP" --force
check "--force overwrites" eval 'rcIs 0 && [ "$(cat "$ROOT/etc/liongard-agent/.machine-guid")" = "$GUID" ]'

print "# --dry-run"
newCase
li restore --from "$LEGACY_BACKUP" --dry-run
check "dry-run prints actions" eval 'rcIs 0 && has "[dry-run] Write" && has ".config.json" && has "Nothing was written"'
check "dry-run writes nothing" eval '[ -z "$(find "$ROOT" -mindepth 1 -print -quit)" ]'
writeConfig "$GUID"
li restore --from "$LEGACY_BACKUP" --dry-run
check "dry-run still refuses an installed agent" eval 'rcIs 1 && has "keeps its own identity"'

print "# tamper and validation"
tamperCopy() { rm -rf "$CASE/bk"; cp -Rp "$TIER1_BACKUP" "$CASE/bk"; chmod -R u+w "$CASE/bk"; }
newCase
tamperCopy; print "eeeeeeee-0000-0000-0000-000000000000" > "$CASE/bk/machine-guid"
li restore --from "$CASE/bk"
check "machine-guid tamper rejected" eval 'rcIs 1 && has "Checksum mismatch" && [ ! -e "$ROOT/etc" ]'
tamperCopy; print ' ' >> "$CASE/bk/config.json"
li restore --from "$CASE/bk" --with-config
check "config tamper rejected" eval 'rcIs 1 && has "Checksum mismatch" && [ ! -e "$ROOT/etc" ]'
tamperCopy; sed -i '' 's/^os=macos$/os=windows/' "$CASE/bk/manifest.txt"
li restore --from "$CASE/bk"
check "wrong os rejected" eval 'rcIs 1 && has "not macos"'
tamperCopy; sed -i '' 's/^format_version=1$/format_version=9/' "$CASE/bk/manifest.txt"
li restore --from "$CASE/bk"
check "wrong format_version rejected" eval 'rcIs 1 && has "format_version"'
tamperCopy; print 'bad guid!' > "$CASE/bk/machine-guid"
sed -i '' "s/^sha256_machine_guid=.*/sha256_machine_guid=$(shasum -a 256 "$CASE/bk/machine-guid" | cut -d' ' -f1)/" "$CASE/bk/manifest.txt"
li restore --from "$CASE/bk"
check "invalid GUID rejected" eval 'rcIs 1 && has "not a valid MachineGuid" && [ ! -e "$ROOT/etc" ]'
tamperCopy; rm "$CASE/bk/manifest.txt"
li restore --from "$CASE/bk"
check "missing manifest rejected" eval 'rcIs 1 && has "not a Liongard identity backup"'
li restore --from "$CASE/nope"
check "missing backup dir rejected" eval 'rcIs 1 && has "does not exist"'

check "real /Library/Liongard/.config.json untouched" eval '[ "$(realStamp)" = "$REAL_BEFORE" ]'

print "\n${PASS} passed, ${FAIL} failed"
(( FAIL == 0 ))
