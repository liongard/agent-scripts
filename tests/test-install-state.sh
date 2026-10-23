#!/usr/bin/env bash
# Tests the install-state decisions of the Linux and macOS scripts with fake services. No network, no root.
# Usage: bash tests/test-install-state.sh   (bash 3.2 or later; needs curl for the Linux file:// download)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/lg-install-state.XXXXXX")" || exit 1
trap 'rm -rf "$WORK"' EXIT
pass=0
fail=0

extract() {
  sed -n "/^# BEGIN SHARED BLOCK: $2\$/,/^# END SHARED BLOCK: $2\$/p" "$1"
}

check() {
  if eval "$2"
  then
    pass=$((pass + 1)); echo "ok    $1"
  else
    fail=$((fail + 1)); echo "FAIL  $1"
    if [ -f "$T/out" ]; then sed 's/^/        | /' "$T/out" | tail -n 25; fi
  fi
}

# Usage: run <name> <expected exit> <function> <args...>. Runs the main function in a subshell.
run() {
  local name="$1" want="$2" rc=0
  shift 2
  ( "$@" ) > "$T/out" 2>&1 || rc=$?
  check "$name (exit $rc, want $want)" '[ "$rc" = "$want" ]'
}

CASE=0
new_case() {
  CASE=$((CASE + 1))
  T="$WORK/$SECTION$CASE"
  mkdir -p "$T/bin" "$T/units" "$T/etc" "$T/log" "$T/ld" "$T/daemons"
}

sleep() { :; }

for tool in sha256sum shasum
do
  if ! command -v "$tool" >/dev/null 2>&1
  then
    mkdir -p "$WORK/shims"
    case "$tool" in
      sha256sum) printf '#!/bin/sh\nshasum -a 256 "$@"\n' > "$WORK/shims/sha256sum" ;;
      shasum) printf '#!/bin/sh\nshift 2; sha256sum "$@"\n' > "$WORK/shims/shasum" ;;
    esac
    chmod +x "$WORK/shims/$tool"
    PATH="$WORK/shims:$PATH"
  fi
done

### Linux

L="$ROOT/linux/LGAgentInstall-Linux-Advanced.sh"
{
  extract "$L" "Liongard shell common functions"
  extract "$L" "Liongard environment check"
  extract "$L" "Liongard Linux agent functions"
} > "$WORK/linux.sh"
if [ ! -s "$WORK/linux.sh" ]; then echo "FAIL  Linux blocks missing"; exit 1; fi

# Fake systemctl: the core service is active while $T/running exists.
linux_shims() {
  cat > "$T/bin/systemctl" <<EOF
#!/bin/sh
case "\$1" in
  is-active)
    [ "\$2" = --quiet ] && shift
    case "\$2" in
      liongard-agent|liongard-agent.service) [ -f "$T/running" ] ;;
      liongard-agent-updater.service) if [ -f "$T/updating" ]; then echo active; else echo inactive; exit 3; fi ;;
      *) exit 3 ;;
    esac ;;
  start) [ -f "$T/start-works" ] && touch "$T/running"; exit 0 ;;
  stop) [ "\$2" = liongard-agent.service ] && rm -f "$T/running"; exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$T/bin/systemctl"
}

# Usage: fake_installer <version|none> <behaviour: ok|fail|norun>
fake_installer() {
  {
    echo '#!/bin/sh'
    echo '# This script was generated using Makeself 2.4.5'
    if [ "$1" != none ]; then echo "if [ \"\$1\" = --tar ]; then echo $1; exit 0; fi"; else echo "if [ \"\$1\" = --tar ]; then exit 1; fi"; fi
    case "$2" in
      fail) echo 'exit 3' ;;
      *)
        echo "touch '$T/installer-ran'; printf '%s\n' \"\$@\" > '$T/installer-args'"
        echo "mkdir -p '$T/agent' && touch '$T/units/liongard-agent.service' '$T/units/liongard-agent-updater.timer'"
        echo "printf '#!/bin/sh\n' > '$T/agent/LiongardAgent' && chmod +x '$T/agent/LiongardAgent'"
        echo "printf 'AGENT_ID=77\nAGENT_VERSION=${1/none/5.6.0}\n' > '$T/agent/.config'"
        if [ "$2" = ok ]; then echo "touch '$T/running'"; fi
        echo 'exit 0' ;;
    esac
    i=0; while [ "$i" -lt 200 ]; do echo "# padding line to pass the minimum installer size check ......"; i=$((i + 1)); done
  } > "$T/fake.run"
}

# A running agent of the given version; "stopped" leaves the service down.
linux_agent() {
  mkdir -p "$T/agent/logs"
  touch "$T/units/liongard-agent.service" "$T/units/liongard-agent-updater.timer"
  printf '#!/bin/sh\n' > "$T/agent/LiongardAgent"; chmod +x "$T/agent/LiongardAgent"
  printf 'AGENT_ID=4242\nMACHINE_GUID=3f2b6c1e-8a4d-4f7e-9b21-0c5d7e8f9a10\nAGENT_NAME=host1\nAGENT_VERSION=%s\nROAR_SECRET_ACCESS_KEY=FAKE-SECRET\n' "$1" > "$T/agent/.config"
  if [ "$2" != stopped ]; then touch "$T/running"; fi
}

linux_env() {
  linux_shims
  PATH="$T/bin:$ORIG_PATH"
  LG_AGENT_DIR="$T/agent"; LG_AGENT_BINARY="$T/agent/LiongardAgent"; LG_AGENT_CONFIG="$T/agent/.config"
  LG_AGENT_LOG="$T/agent/logs/agent.log"; LG_GUID_DIR="$T/etc/liongard-agent"; LG_GUID_FILE="$T/etc/liongard-agent/.machine-guid"
  LG_MACHINE_ID_FILES="$T/etc/machine-id"; LG_UNIT_DIRS="$T/units"; LG_AGENT_DIRS="$T/agent"
  LG_LEGACY_BINARIES=""; LG_UNINSTALL_SCRIPTS=""; LG_LEGACY_SERVICES=""; LG_LEGACY_UPDATER_TIMERS=""
  INSTANCE_PREFIX=us1; AGENT_TOKEN_KEY=FAKEKEY1; AGENT_TOKEN_SECRET=FAKESECRET1; ENVIRONMENT=Acme
  INCLUDE_ENVIRONMENT_VALUE=true; AGENT_NAME=""; AGENT_DESCRIPTION=""; PROXY_URL=""; DEVICE_GUID=""; RESET_IDENTITY=false
  LINUX_ARCHITECTURE=auto; INSTALLER_URL="file://$T/fake.run"; INSTALLER_FILE_NAME=""; LOG_DIRECTORY="$T/log"
  API_TOKEN_KEY=FAKEAPIKEY; API_TOKEN_SECRET=FAKEAPISECRET
  LG_SECRETS=(); LG_LOG_FILE=""
}

ORIG_PATH="$PATH"
SECTION=linux
(
  # shellcheck disable=SC1090,SC1091
  . "$WORK/linux.sh"
  lg_require_root() { :; }
  lg_deb_packages() { :; }
  lg_rpm_packages() { :; }

  state() { lg_install_state "$1" >/dev/null 2>&1; printf '%s' "$LG_STATE"; }

  new_case; linux_env
  check "Linux: nothing present is NotInstalled" '[ "$(state)" = NotInstalled ]'
  linux_agent 5.5.0
  check "Linux: unit, binary, config and running service is Healthy" '[ "$(state)" = Healthy ]'
  rm -f "$T/running"
  check "Linux: a stopped service is Stale" '[ "$(state)" = Stale ]'
  touch "$T/running"; rm -f "$T/agent/.config"
  check "Linux: a running service without its config is Stale" '[ "$(state)" = Stale ]'

  new_case; linux_env; linux_agent 5.5.0
  for i in 1 2 3; do printf '{"level":"error","caller":"http/heartbeat.go:72","msg":"heartbeat failed","status_code":401}\n' >> "$T/agent/logs/agent.log"; done
  check "Linux: three 401 heartbeats make Clean Install see Stale" '[ "$(state clean)" = Stale ]'
  check "Linux: Install Simple ignores the 401 rule (still Healthy)" '[ "$(state)" = Healthy ]'
  printf '{"level":"error","caller":"http/heartbeat.go:72","msg":"heartbeat failed","error":"dial tcp: timeout"}\n' >> "$T/agent/logs/agent.log"
  check "Linux: a network error breaks the 401 run" '[ "$(state clean)" = Healthy ]'

  new_case; linux_env; INSTANCE_PREFIX="REPLACE_WITH_INSTANCE_PREFIX"; fake_installer 5.6.0 ok
  run "Linux Simple: placeholder value exits 2" 2 lg_install_main simple
  check "Linux Simple: placeholder run changes nothing" '[ ! -f "$T/installer-ran" ]'

  new_case; linux_env; linux_agent 5.5.0 stopped; fake_installer 5.6.0 ok
  run "Linux Simple: Stale agent exits 8" 8 lg_install_main simple
  check "Linux Simple: Stale agent is left as it is" '[ ! -f "$T/installer-ran" ] && [ -f "$T/agent/.config" ]'

  new_case; linux_env; linux_agent 5.5.0; fake_installer 5.5.0 ok
  run "Linux Simple: Healthy agent, same version exits 0" 0 lg_install_main simple
  check "Linux Simple: same version does not run the installer" '[ ! -f "$T/installer-ran" ] && grep -q "Nothing to do" "$T/out"'

  new_case; linux_env; linux_agent 5.6.0; fake_installer 5.5.0 ok
  run "Linux Simple: Healthy agent, older installer exits 0" 0 lg_install_main simple
  check "Linux Simple: older installer is not run" '[ ! -f "$T/installer-ran" ]'

  new_case; linux_env; linux_agent 5.5.0; fake_installer 5.6.0 ok
  run "Linux Simple: Healthy agent, newer installer upgrades" 0 lg_install_main simple
  check "Linux Simple: the upgrade ran the installer" '[ -f "$T/installer-ran" ]'

  new_case; linux_env; linux_agent 5.5.0; fake_installer none ok
  run "Linux Simple: Healthy agent, unreadable installer version exits 5" 5 lg_install_main simple
  check "Linux Simple: unreadable version changes nothing" '[ ! -f "$T/installer-ran" ]'

  new_case; linux_env; fake_installer 5.6.0 ok
  run "Linux Simple: NotInstalled installs" 0 lg_install_main simple
  check "Linux Simple: installer got the settings" 'grep -qx -- "-u" "$T/installer-args" && grep -qx us1.app.liongard.com "$T/installer-args" && grep -qx Acme "$T/installer-args"'
  check "Linux Simple: the secrets are masked in the log" '! grep -rq -e FAKESECRET1 -e FAKEKEY1 "$T/log"'

  new_case; linux_env; fake_installer 5.6.0 fail
  run "Linux Simple: a failing installer exits 6" 6 lg_install_main simple

  new_case; linux_env; fake_installer 5.6.0 norun
  run "Linux Simple: installed but not running exits 7" 7 lg_install_main simple

  new_case; linux_env; INSTALLER_URL="file://$T/missing.run"
  run "Linux Simple: a failed download exits 5" 5 lg_install_main simple

  new_case; linux_env; fake_installer 5.6.0 ok
  _api_get() { return 22; }
  run "Linux Advanced: environment lookup failure exits 4" 4 lg_install_main advanced
  check "Linux Advanced: the failed lookup changes nothing" '[ ! -f "$T/installer-ran" ]'
  _api_get() { printf '[{"ID":1,"Name":"Acme Corp"},{"ID":2,"Name":"Other"}]'; }
  ENVIRONMENT="ACME CORP"
  run "Linux Advanced: environment matched case-insensitively installs" 0 lg_install_main advanced
  check "Linux Advanced: the installer got the platform's environment name" 'grep -qx "Acme Corp" "$T/installer-args"'
  new_case; linux_env; fake_installer 5.6.0 ok; ENVIRONMENT="Nowhere"
  _api_get() { printf '[{"ID":1,"Name":"Acme Corp"}]'; }
  run "Linux Advanced: environment not found exits 4" 4 lg_install_main advanced

  new_case; linux_env; linux_agent 5.5.0 stopped; fake_installer 5.6.0 ok
  run "Linux Clean: Stale agent is removed and reinstalled" 0 lg_install_main clean
  check "Linux Clean: identity backup written before the removal" 'ls -d "$T"/log/liongard-identity-* >/dev/null 2>&1'
  check "Linux Clean: identity seeded from the config" 'grep -qx 3f2b6c1e-8a4d-4f7e-9b21-0c5d7e8f9a10 "$T/etc/liongard-agent/.machine-guid"'
  check "Linux Clean: the installer ran" '[ -f "$T/installer-ran" ]'
  check "Linux Clean: no secret in the backup" '! grep -rq FAKE-SECRET "$T"/log/liongard-identity-*'

  new_case; linux_env; linux_agent 5.5.0 stopped; touch "$T/start-works"; fake_installer 5.5.0 ok
  run "Linux Clean: a stopped agent that starts is Healthy, nothing to do" 0 lg_install_main clean
  check "Linux Clean: the started agent is not reinstalled" '[ ! -f "$T/installer-ran" ]'

  new_case; linux_env; linux_agent 5.5.0 stopped; touch "$T/updating"; fake_installer 5.6.0 ok
  run "Linux Clean: an update that keeps running exits 11" 11 lg_install_main clean

  new_case; linux_env; linux_agent 5.5.0; fake_installer 5.5.0 ok
  for i in 1 2 3; do printf '{"caller":"http/heartbeat.go:72","status_code":401}\n' >> "$T/agent/logs/agent.log"; done
  run "Linux Clean: an agent the platform refuses (401) is reinstalled" 0 lg_install_main clean
  check "Linux Clean: the refused agent was reinstalled" '[ -f "$T/installer-ran" ]'

  new_case; linux_env; linux_agent 5.5.0
  run "Linux Uninstall Simple: removes the agent" 0 lg_uninstall_main simple
  check "Linux Uninstall Simple: agent folder and units are gone" '[ ! -e "$T/agent" ] && [ ! -e "$T/units/liongard-agent.service" ]'
  check "Linux Uninstall Simple: identity backup written" 'ls -d "$T"/log/liongard-identity-* >/dev/null 2>&1'

  new_case; linux_env; mkdir -p "$T/agent"; printf 'AGENT_ID=1\n' > "$T/agent/.config"
  run "Linux Uninstall Simple: a config with no identity exits 12 and removes nothing" 12 lg_uninstall_main simple
  check "Linux Uninstall Simple: nothing removed after the backup failure" '[ -f "$T/agent/.config" ]'

  echo "$pass $fail" > "$WORK/linux-result"
)
SECTION=macos
read -r pass fail < "$WORK/linux-result" 2>/dev/null || { fail=1; echo "FAIL  Linux section did not finish"; }

### macOS

M="$ROOT/macos/LGAgentInstall-macOS-Advanced.sh"
{
  extract "$M" "Liongard shell common functions"
  extract "$M" "Liongard environment check"
  extract "$M" "Liongard macOS agent functions"
} > "$WORK/macos.sh"
if [ ! -s "$WORK/macos.sh" ]; then echo "FAIL  macOS blocks missing"; exit 1; fi

# Fake launchctl: a job is loaded while $T/ld/<label> exists and runs while $T/ld/<label>.running exists.
mac_shims() {
  cat > "$T/bin/launchctl" <<EOF
#!/bin/sh
label="\${2#system/}"
case "\$1" in
  print) [ -f "$T/ld/\$label" ] || exit 113
         if [ -f "$T/ld/\$label.running" ]; then echo "state = running"; else echo "state = not running"; fi ;;
  bootout) rm -f "$T/ld/\$label" "$T/ld/\$label.running" ;;
  kickstart) [ "\$2" = -k ] && label="\${3#system/}"; touch "$T/kickstarted"; [ -f "$T/start-works" ] && touch "$T/ld/\$label.running"; exit 0 ;;
  bootstrap) touch "$T/ld/com.liongard.liongard-agent" ;;
esac
exit 0
EOF
  printf '#!/bin/sh\nexit 1\n' > "$T/bin/pkgutil"
  printf '#!/bin/sh\necho "  | \\"IOPlatformUUID\\" = \\"A1B2C3D4-E5F6-4711-8899-AABBCCDDEEFF\\""\n' > "$T/bin/ioreg"
  printf '#!/bin/sh\nexit 1\n' > "$T/bin/pgrep"
  cat > "$T/bin/installer" <<EOF
#!/bin/sh
touch "$T/installer-ran"
[ -f "$T/installer-fails" ] && exit 1
mkdir -p "$T/agent"
touch "$T/daemons/com.liongard.liongard-agent.plist" "$T/daemons/com.liongard.liongard-agent-updater.plist" "$T/ld/com.liongard.liongard-agent"
[ -f "$T/installer-starts" ] && touch "$T/ld/com.liongard.liongard-agent.running"
[ -f "$T/agent/.config.json" ] || printf '{"AGENT_ID":"77","AGENT_VERSION":"5.6.0"}\n' > "$T/agent/.config.json"
printf '#!/bin/sh\n' > "$T/agent/LiongardAgent"; chmod +x "$T/agent/LiongardAgent"
exit 0
EOF
  chmod +x "$T/bin/"*
  touch "$T/installer-starts"
}

mac_agent() {
  mkdir -p "$T/agent/logs"
  touch "$T/daemons/com.liongard.liongard-agent.plist" "$T/daemons/com.liongard.liongard-agent-updater.plist" "$T/ld/com.liongard.liongard-agent"
  printf '#!/bin/sh\n' > "$T/agent/LiongardAgent"; chmod +x "$T/agent/LiongardAgent"
  printf '{\n"AGENT_ID":"4242",\n"MACHINE_GUID":"3f2b6c1e-8a4d-4f7e-9b21-0c5d7e8f9a10",\n"AGENT_VERSION":"%s",\n"ROAR_SECRET_ACCESS_KEY":"FAKE-SECRET"\n}\n' "$1" > "$T/agent/.config.json"
  if [ "$2" != stopped ]; then touch "$T/ld/com.liongard.liongard-agent.running"; fi
}

mac_env() {
  mac_shims
  PATH="$T/bin:$ORIG_PATH"
  LG_AGENT_DIR="$T/agent"; LG_AGENT_BINARY="$T/agent/LiongardAgent"; LG_AGENT_CONFIG="$T/agent/.config.json"
  LG_AGENT_LOG="$T/agent/logs/agent.log"; LG_PKG_UNINSTALL="$T/agent/uninstall.sh"; LG_DAEMON_DIR="$T/daemons"
  LG_GUID_DIR="$T/etc/liongard-agent"; LG_GUID_FILE="$T/etc/liongard-agent/.machine-guid"
  INSTANCE_URL=us1; ACCESS_KEY_ID=FAKEKEY1; ACCESS_KEY_SECRET=FAKESECRET1; ENVIRONMENT=Acme; INCLUDE_ENVIRONMENT_VALUE=true
  NAME=""; AGENT_DESCRIPTION=""; MAC_ARCHITECTURE=auto; PKG_PATH=""; LOG_DIRECTORY="$T/log"
  API_TOKEN_KEY=FAKEAPIKEY; API_TOKEN_SECRET=FAKEAPISECRET; PKG_VERSION=5.6.0
  LG_SECRETS=(); LG_LOG_FILE=""
}

(
  # shellcheck disable=SC1090,SC1091
  . "$WORK/macos.sh"
  lg_require_root() { :; }
  lg_clear_handoff() { :; }
  lg_ensure_rosetta() { :; }
  lg_write() { printf '%s=%s\n' "$2" "$1" >> "$T/handoff"; }
  lg_fetch_package() { LG_PKG="$T/fake.pkg"; LG_PKG_VERSION="$PKG_VERSION"; [ "$PKG_VERSION" != fail ] || lg_exit "$EXIT_DOWNLOAD" "fake download failure"; [ "$PKG_VERSION" != none ] || LG_PKG_VERSION=""; }
  lg_set_config_version() { sed -i.bak "s/\"AGENT_VERSION\":\"[^\"]*\"/\"AGENT_VERSION\":\"$1\"/" "$LG_AGENT_CONFIG"; }

  state() { lg_install_state "$1" >/dev/null 2>&1; printf '%s' "$LG_STATE"; }

  new_case; mac_env
  check "macOS: nothing present is NotInstalled" '[ "$(state)" = NotInstalled ]';
  mac_agent 5.5.0
  check "macOS: plist, binary, config and running job is Healthy" '[ "$(state)" = Healthy ]'
  rm -f "$T/ld/com.liongard.liongard-agent.running"
  check "macOS: a loaded but stopped job is Stale" '[ "$(state)" = Stale ]'
  touch "$T/ld/com.liongard.liongard-agent.running"
  for i in 1 2 3; do printf '{"caller":"http/heartbeat.go:72","status_code":401}\n' >> "$T/agent/logs/agent.log"; done
  check "macOS: three 401 heartbeats make Clean Install see Stale" '[ "$(state clean)" = Stale ]'

  new_case; mac_env; ACCESS_KEY_SECRET=""
  run "macOS Simple: blank required value exits 2" 2 lg_install_main simple

  new_case; mac_env; mac_agent 5.5.0 stopped
  run "macOS Simple: Stale agent exits 8" 8 lg_install_main simple
  check "macOS Simple: Stale agent is left as it is" '[ ! -f "$T/installer-ran" ] && [ -f "$T/agent/.config.json" ]'

  new_case; mac_env; mac_agent 5.6.0
  run "macOS Simple: Healthy agent, same version exits 0" 0 lg_install_main simple
  check "macOS Simple: same version does not run the installer" '[ ! -f "$T/installer-ran" ]'

  new_case; mac_env; mac_agent 5.5.0; PKG_VERSION=none
  run "macOS Simple: Healthy agent, unreadable package version exits 5" 5 lg_install_main simple

  new_case; mac_env; mac_agent 5.5.0; touch "$T/start-works"
  run "macOS Simple: Healthy agent, newer package upgrades" 0 lg_install_main simple
  check "macOS Simple: the upgrade ran the installer and restarted the agent" '[ -f "$T/installer-ran" ] && [ -f "$T/kickstarted" ]'
  check "macOS Simple: the upgrade wrote no handoff files" '[ ! -f "$T/handoff" ]'
  check "macOS Simple: the upgrade recorded the new version" 'grep -q "\"AGENT_VERSION\":\"5.6.0\"" "$T/agent/.config.json"'

  new_case; mac_env
  run "macOS Simple: NotInstalled installs" 0 lg_install_main simple
  check "macOS Simple: handoff files carry the settings" 'grep -qx /tmp/liongard_instance_url=us1.app.liongard.com "$T/handoff" && grep -qx /tmp/liongard_environment=Acme "$T/handoff"'
  check "macOS Simple: the secrets are masked in the log" '! grep -rq -e FAKESECRET1 -e FAKEKEY1 "$T/log"'

  new_case; mac_env; touch "$T/installer-fails"
  run "macOS Simple: a failing installer exits 6" 6 lg_install_main simple

  new_case; mac_env; rm -f "$T/installer-starts"
  run "macOS Simple: installed but not running exits 7" 7 lg_install_main simple

  new_case; mac_env; PKG_VERSION=fail
  run "macOS Simple: a failed download exits 5" 5 lg_install_main simple

  new_case; mac_env
  _api_get() { return 22; }
  run "macOS Advanced: environment lookup failure exits 4" 4 lg_install_main advanced
  _api_get() { printf '[{"ID":1,"Name":"Acme Holdings"},{"ID":2,"Name":"Acme Holdings West"}]'; }
  ENVIRONMENT="acme"
  run "macOS Advanced: a short name never prefix-matches (exit 4)" 4 lg_install_main advanced
  ENVIRONMENT="Acme Holdings"
  run "macOS Advanced: exact environment installs" 0 lg_install_main advanced

  new_case; mac_env; mac_agent 5.5.0 stopped
  run "macOS Clean: Stale agent is removed and reinstalled" 0 lg_install_main clean
  check "macOS Clean: identity backup written before the removal" 'ls -d "$T"/log/liongard-identity-* >/dev/null 2>&1'
  check "macOS Clean: identity seeded from the config" 'grep -qx 3f2b6c1e-8a4d-4f7e-9b21-0c5d7e8f9a10 "$T/etc/liongard-agent/.machine-guid"'
  check "macOS Clean: the installer ran" '[ -f "$T/installer-ran" ]'

  new_case; mac_env; mac_agent 5.5.0
  run "macOS Uninstall Simple: removes the agent" 0 lg_uninstall_main simple
  check "macOS Uninstall Simple: agent folder and plists are gone" '[ ! -e "$T/agent" ] && [ ! -e "$T/daemons/com.liongard.liongard-agent.plist" ]'
  check "macOS Uninstall Simple: identity backup written" 'ls -d "$T"/log/liongard-identity-* >/dev/null 2>&1'

  echo "$pass $fail" > "$WORK/mac-result"
)
# The macOS subshell starts from the Linux totals, so its result is the running total.
read -r pass fail < "$WORK/mac-result" 2>/dev/null || { fail=$((fail + 1)); echo "FAIL  macOS section did not finish"; }

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
