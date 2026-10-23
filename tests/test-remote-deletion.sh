#!/usr/bin/env bash
# Tests the shared platform-record removal block against a mocked Liongard API. No network, no root.
# Usage: bash tests/test-remote-deletion.sh   (bash 3.2 or later; needs jq)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LINUX="$ROOT/linux/LGAgentUninstall-Linux-Advanced.sh"
MAC="$ROOT/macos/LGAgentUninstall-macOS-Advanced.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/lg-remote-deletion.XXXXXX")" || exit 1
trap 'rm -rf "$WORK"' EXIT
pass=0
fail=0

extract() {
  sed -n "/^# BEGIN SHARED BLOCK: $2\$/,/^# END SHARED BLOCK: $2\$/p" "$1"
}

for block in "Liongard shell common functions" "Liongard platform record removal"
do
  extract "$LINUX" "$block" > "$WORK/linux.sh"
  extract "$MAC" "$block" > "$WORK/mac.sh"
  if [ ! -s "$WORK/linux.sh" ] || ! cmp -s "$WORK/linux.sh" "$WORK/mac.sh"
  then
    echo "FAIL  shared block [$block] differs between the Linux and macOS uninstall scripts (or is missing)"
    exit 1
  fi
  cat "$WORK/linux.sh" >> "$WORK/blocks.sh"
done
echo "ok    shared blocks are identical in both scripts"

# shellcheck disable=SC1090,SC1091
. "$WORK/blocks.sh"

_log() { printf '%s %s\n' "$1" "$2" >> "$WORK/log"; }

# Mocked server: "=" is exact and case-sensitive, "like 'x%'" a case-sensitive prefix, as in roar-api.
# Deletes go to a file because the block calls _api_delete in a subshell.
_server_agents() {
  jq -c --argjson gone "$(jq -R . < "$WORK/deleted" | jq -sc .)" '[.[] | select((.ID | tostring) as $i | ($gone | index($i)) | not)]' <<< "$FIX_AGENTS"
}

_api_get() {
  local path="$1" cond field op value q="'"
  printf '%s\n' "$path" >> "$WORK/calls"
  if [ -n "${FAIL_GET:-}" ] && [[ "$path" == *"$FAIL_GET"* ]]
  then
    return 22
  fi
  case "$path" in
    /environments) printf '%s' "$FIX_ENVS" ;;
    /agents\?conditions=*)
      cond="$(printf '%b' "$(printf '%s' "${path#*conditions=}" | sed 's/%/\\x/g')")"
      field="${cond%% *}"
      op="${cond#* }"; op="${op%% $q*}"
      value="${cond#*$q}"
      value="${value%$q}"
      value="${value//$q$q/$q}"
      case "$op" in
        "=") _server_agents | jq -c --arg f "$field" --arg v "$value" '[.[] | select((.[$f] // "" | tostring) == $v)]' ;;
        like) _server_agents | jq -c --arg f "$field" --arg v "${value%\%}" '[.[] | select((.[$f] // "" | tostring) | startswith($v))]' ;;
        *) return 22 ;;
      esac
      ;;
    /agents/*) _server_agents | jq -c --arg id "${path#/agents/}" '[.[] | select((.ID | tostring) == $id)]' ;;
    *) return 22 ;;
  esac
}

_api_delete() {
  local id="${1#/agents/}"
  printf 'DELETE %s\n' "$id" >> "$WORK/calls"
  case "${DELETE_MODE:-ok}" in
    ok) printf '%s\n' "$id" >> "$WORK/deleted"; printf '200' ;;
    timeout) printf '%s\n' "$id" >> "$WORK/deleted"; printf '000'; return 28 ;;
    fail) printf '500'; return 0 ;;
  esac
}

reset_case() {
  : > "$WORK/log"; : > "$WORK/calls"; : > "$WORK/deleted"
  LG_ID_AGENT_ID="" LG_ID_AGENT="" LG_ID_OS="" FAIL_GET="" DELETE_MODE=ok
  FIX_ENVS='[{"ID":7,"Name":"Acme"},{"ID":8,"Name":"Other"}]'
}

check() {
  if eval "$2"
  then
    pass=$((pass + 1)); echo "ok    $1"
  else
    fail=$((fail + 1)); echo "FAIL  $1"
    sed 's/^/        | /' "$WORK/log"
  fi
}

# Usage: expect <name> <expected rc> <expected deleted ids, space separated> -- <command...>
expect() {
  local name="$1" want_rc="$2" want_del="$3" rc=0 got_del
  shift 4
  "$@" || rc=$?
  got_del="$(tr '\n' ' ' < "$WORK/deleted" | sed 's/ $//')"
  if [ "$rc" = "$want_rc" ] && [ "$got_del" = "$want_del" ]
  then
    pass=$((pass + 1)); echo "ok    $name"
  else
    fail=$((fail + 1)); echo "FAIL  $name: rc=$rc (want $want_rc), deleted [$got_del] (want [$want_del])"
    sed 's/^/        | /' "$WORK/log"
  fi
}

A='{"ID":101,"Name":"HOST1","Hostname":"host1","MachineGuid":"aaaa-1111","Environment":{"ID":7,"Name":"Acme"}}'
B='{"ID":102,"Name":"HOST1","Hostname":"host1","MachineGuid":"bbbb-2222","Environment":{"ID":7,"Name":"Acme"}}'
C='{"ID":103,"Name":"host1","Hostname":"host1","MachineGuid":"aaaa-1111","Environment":{"ID":8,"Name":"Other"}}'
D='{"ID":104,"Name":"host1","Hostname":"host1","MachineGuid":"","Environment":null}'

reset_case
lg_id_add LG_ID_AGENT guid-file "AAAA-1111"
lg_id_add LG_ID_AGENT config "{aaaa-1111}"
lg_id_add LG_ID_OS machine-id "aaaa-1111"
check "lg_id_add dedupes across both lists, ignoring case and braces" '[ "$(lg_values "$LG_ID_AGENT$LG_ID_OS")" = "AAAA-1111" ]'

reset_case
for junk in "" local LOCAL uninitialized 00000000-0000-0000-0000-000000000000 "{00000000-0000-0000-0000-000000000000}" "zzzz-yyyy" "----"
do
  lg_id_add LG_ID_AGENT test "$junk"
done
check "(e) junk identifiers are never added" '[ -z "$LG_ID_AGENT" ]'
check "(e) a real identifier is not junk" '! lg_is_junk_id "5f3c0a9e-1b2d-4c3e-8f00-123456789abc"'

reset_case; FIX_AGENTS="[$A,$B]"
LG_ID_AGENT_ID=101; lg_id_add LG_ID_AGENT guid-file aaaa-1111
expect "AgentID with matching MachineGuid is deleted" 0 "101" -- lg_remove_platform_record "Acme" host1
check "AgentID match runs no later lookups" '! grep -q conditions "$WORK/calls"'

reset_case; FIX_AGENTS="[$B]"
LG_ID_AGENT_ID=102; lg_id_add LG_ID_AGENT guid-file aaaa-1111
expect "AgentID whose MachineGuid differs is a conflict, not deleted" 1 "" -- lg_remove_platform_record "Acme" host1

reset_case; FIX_AGENTS='[{"ID":110,"Name":"other-pc","Hostname":"other-pc","MachineGuid":"","Environment":{"ID":8,"Name":"Other"}}]'
LG_ID_AGENT_ID=110
expect "(a) AgentID record with no name and no environment match is refused" 1 "" -- lg_remove_platform_record "Acme" host1
check "(a) the refusal is logged with the record's signals" 'grep -q "Agent ID 110: .*neither a local name nor the environment matches" "$WORK/log"'

reset_case; FIX_AGENTS='[{"ID":111,"Name":"HOST1","Hostname":"x","MachineGuid":"","Environment":{"ID":8,"Name":"Other"}}]'
LG_ID_AGENT_ID=111
expect "(a) AgentID record whose Name matches a local name is deleted" 0 "111" -- lg_remove_platform_record "Acme" host1

reset_case; FIX_AGENTS='[{"ID":112,"Name":"renamed","Hostname":"renamed","Data":{"FQDN":"host1.corp.example"},"MachineGuid":"","Environment":{"ID":8,"Name":"Other"}}]'
LG_ID_AGENT_ID=112
expect "(a) AgentID record whose FQDN matches a local name is deleted" 0 "112" -- lg_remove_platform_record "Acme" host1 host1.corp.example

reset_case; FIX_AGENTS='[{"ID":113,"Name":"renamed","Hostname":"renamed","MachineGuid":"","Environment":{"ID":7,"Name":"Acme"}}]'
LG_ID_AGENT_ID=113
expect "(a) AgentID record in the configured environment is deleted" 0 "113" -- lg_remove_platform_record "acme" host1

reset_case; FIX_AGENTS='[{"ID":114,"Name":"renamed","Hostname":"renamed","MachineGuid":"dddd-4444","Environment":{"ID":7,"Name":"Acme"}}]'
LG_ID_AGENT_ID=114; lg_id_add LG_ID_OS machine-id dddd-4444
expect "(e) AgentID record matched only by an OS identifier and no name is refused" 1 "" -- lg_remove_platform_record "Acme" host1

reset_case; FIX_AGENTS="[$A,$B]"
LG_ID_AGENT_ID=999; lg_id_add LG_ID_AGENT config AAAA-1111
expect "unknown AgentID falls back to one MachineGuid match (lowercase form queried)" 0 "101" -- lg_remove_platform_record "acme" host1

reset_case; FIX_AGENTS='[{"ID":120,"Name":"x","Hostname":"x","MachineGuid":"aaaa-1111\n","Environment":{"ID":7,"Name":"Acme"}}]'
lg_id_add LG_ID_AGENT config aaaa-1111
expect "(c) a record MachineGuid with a trailing newline is found by like and matched trimmed" 0 "120" -- lg_remove_platform_record "Acme" host1
check "(c) the MachineGuid step queried with like" 'grep -q "MachineGuid%20like%20%27aaaa-1111%25%27" "$WORK/calls"'

reset_case; FIX_AGENTS='[{"ID":121,"Name":"x","Hostname":"x","MachineGuid":"aaaa-1111-extra","Environment":{"ID":7,"Name":"Acme"}}]'
lg_id_add LG_ID_AGENT config aaaa-1111
expect "(c) a like hit with a longer MachineGuid is filtered out on the client" 2 "" -- lg_remove_platform_record "Acme" host1

reset_case; FIX_AGENTS="[$A,$C]"
lg_id_add LG_ID_AGENT config aaaa-1111
expect "MachineGuid match is limited to the environment" 0 "101" -- lg_remove_platform_record "Acme" host1

reset_case; FIX_AGENTS="[$A,${A/101/105}]"
lg_id_add LG_ID_AGENT config aaaa-1111
expect "(g) two MachineGuid matches are refused" 1 "" -- lg_remove_platform_record "Acme" host1
check "(g) both candidates are logged" 'grep -q "Agent ID 101:" "$WORK/log" && grep -q "Agent ID 105:" "$WORK/log"'

reset_case; FIX_AGENTS='[{"ID":130,"Name":"clone","Hostname":"clone","MachineGuid":"eeee-5555","Environment":{"ID":7,"Name":"Acme"}}]'
lg_id_add LG_ID_OS machine-id eeee-5555
expect "(e) an OS identifier match without a name match is not deleted" 2 "" -- lg_remove_platform_record "Acme" host1

reset_case; FIX_AGENTS='[{"ID":131,"Name":"host1","Hostname":"host1","MachineGuid":"eeee-5555","Environment":{"ID":7,"Name":"Acme"}}]'
lg_id_add LG_ID_OS machine-id eeee-5555
expect "(e) an OS identifier match with a name match is deleted" 0 "131" -- lg_remove_platform_record "Acme" host1

reset_case; FIX_AGENTS='[{"ID":132,"Name":"host1","Hostname":"host1","MachineGuid":"local","Environment":{"ID":7,"Name":"Acme"}}]'
lg_id_add LG_ID_AGENT config local
expect "(e) a junk local identifier is never queried; the hostname step finds the record" 0 "132" -- lg_remove_platform_record "Acme" host1
check "(e) no MachineGuid query for a junk value" '! grep -q "MachineGuid" "$WORK/calls"'

reset_case; FIX_AGENTS="[$C,$B]"
lg_id_add LG_ID_AGENT config aaaa-1111
expect "(b) hostname step skips a record whose MachineGuid matches no local identifier" 2 "" -- lg_remove_platform_record "Acme" host1
check "(b) the skipped record is logged with the reason" 'grep -q "Agent ID 102: .*MachineGuid is set and matches no local identifier" "$WORK/log"'

reset_case; FIX_AGENTS='[{"ID":140,"Name":"host1","Hostname":"host1","MachineGuid":"","Environment":{"ID":7,"Name":"Acme"}},{"ID":141,"Name":"host1","Hostname":"host1","MachineGuid":"ffff-6666","Environment":{"ID":7,"Name":"Acme"}}]'
lg_id_add LG_ID_AGENT config aaaa-1111
expect "(b) hostname step keeps a record with no MachineGuid and drops the foreign one" 0 "140" -- lg_remove_platform_record "Acme" host1

reset_case; FIX_AGENTS='[{"ID":142,"Name":"HOST1","Hostname":"host1","MachineGuid":"","Environment":{"ID":7,"Name":"Acme"}},{"ID":143,"Name":"host1","Hostname":"host1","MachineGuid":"","Environment":{"ID":7,"Name":"Acme"}}]'
expect "(g) two hostname matches are refused" 1 "" -- lg_remove_platform_record "Acme" host1

reset_case; FIX_AGENTS="[$A,$D]"
expect "blank environment matches only an agent with no environment" 0 "104" -- lg_remove_platform_record "" host1

reset_case; FIX_AGENTS="[$C]"
expect "no match anywhere returns 2" 2 "" -- lg_remove_platform_record "Acme" host1

reset_case; FIX_AGENTS="[$A]"; FAIL_GET="MachineGuid"
lg_id_add LG_ID_AGENT config aaaa-1111
expect "(g) a failed MachineGuid lookup stops the removal" 1 "" -- lg_remove_platform_record "Acme" host1

reset_case; FIX_AGENTS="[$A]"; FAIL_GET="/agents/101"
LG_ID_AGENT_ID=101
expect "(g) a failed AgentID lookup stops the removal" 1 "" -- lg_remove_platform_record "Acme" host1

reset_case; FIX_AGENTS="[$A]"; FAIL_GET="Hostname"
expect "(g) a failed hostname lookup stops the removal" 1 "" -- lg_remove_platform_record "Acme" host1

reset_case; FIX_AGENTS="[$A]"; DELETE_MODE=timeout
LG_ID_AGENT_ID=101; lg_id_add LG_ID_AGENT config aaaa-1111
expect "(g) a delete that times out but removed the record counts as deleted (GET confirms)" 0 "101" -- lg_remove_platform_record "Acme" host1

reset_case; FIX_AGENTS="[$A]"; DELETE_MODE=fail
LG_ID_AGENT_ID=101; lg_id_add LG_ID_AGENT config aaaa-1111
expect "(g) a delete that leaves the record is a failure" 1 "" -- lg_remove_platform_record "Acme" host1

reset_case; FIX_AGENTS='[{"ID":106,"Name":"host1","Hostname":"host1","MachineGuid":"","EnvironmentID":7}]'
expect "an environment given only by ID is resolved by name" 0 "106" -- lg_remove_platform_record "Acme" HOST1

reset_case; FIX_AGENTS='[{"ID":107,"Name":"o'"'"'brien","Hostname":"o'"'"'brien","Environment":null}]'
expect "a hostname with a quote is escaped in the filter" 0 "107" -- lg_remove_platform_record "" "o'brien"

reset_case; FIX_AGENTS="[$A]"
LG_ID_AGENT_ID="12x"
expect "a non-numeric local AgentID fails" 1 "" -- lg_remove_platform_record "Acme" host1

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
