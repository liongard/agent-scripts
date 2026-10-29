# macOS

`LGAgentInstall-macOS.sh` installs the Liongard Agent on macOS, and `LGAgentUninstall-macOS.sh` removes it. For other platforms, and for what you need before you start, see the [main README](../README.md).

## Scripts

| Script | What it does | Use it when |
|---|---|---|
| `LGAgentInstall-macOS.sh` | Downloads and checks the agent package for the Mac's CPU (or uses one your MDM staged), hands it your settings and installs it, or upgrades an older running agent. | Installing or upgrading the agent on a Mac with Intel or Apple Silicon. |
| `LGAgentUninstall-macOS.sh` | Removes the agent from the Mac: both LaunchDaemons, processes, `/Library/Liongard`, the package receipts and leftover settings files in `/tmp`. No Liongard API calls and no settings to fill in. The agent's record stays on the platform. | Removing the agent from a Mac. |

What the install script does, in order:

1. **If the agent is already installed and running,** it reads the installed version from `/Library/Liongard/.config.json` (`AGENT_VERSION`). If it can't read it, the script exits `0` without changes. Otherwise it continues with the steps below to get the package and compares versions before installing anything (see [Upgrades](#upgrades)).
2. Picks the package for the Mac's CPU, using `sysctl -n hw.optional.arm64`, which is correct even under Rosetta:
   - Intel: `https://agents.static.liongard.com/LiongardAgent-lts.pkg`
   - Apple Silicon: `https://agents.static.liongard.com/LiongardAgent-lts-arm64.pkg`

   It downloads the package with retries, unless `PKG_PATH` points to one already on the Mac.
3. Checks the package before installing. The download size must match the server's `Content-Length`, and the package must be at least 20 MB, signed with Liongard's Developer ID Installer certificate (Team ID `KU4C98N3LW`), and built for this Mac. SHA-256 checks will be added once checksum files are published ([#3](https://github.com/liongard/agent-scripts/issues/3)).
4. Installs Rosetta 2 silently if the Intel package is used on Apple Silicon and Rosetta is missing.
5. Hands your settings to the package on a new install (an upgrade keeps the existing registration and hands over nothing; see [Logs and files](#logs-and-files)), runs `installer`, and confirms the agent is running. If registration fails because `ENVIRONMENT` doesn't exist in Liongard, it installs once more without it (see [Missing environment](#missing-environment)).

What the uninstall script does, in order:

1. Runs the package's own `/Library/Liongard/uninstall.sh` when it's there and is a root-owned file only root can change, and `/Library/Liongard` is owned by root, is not a symlink and is not writable by the group or other users. That script removes the LaunchDaemons only when they're loaded, so the next steps always run.
2. Stops `system/com.liongard.liongard-agent` and `system/com.liongard.liongard-agent-updater` (`launchctl bootout`) and removes both plists from `/Library/LaunchDaemons`.
3. Stops leftover processes running from `/Library/Liongard`, then removes `/Library/Liongard`.
4. Forgets the package receipts `com.liongard.LiongardAgent` and `com.liongard.liongard-agent.app` (`pkgutil --forget`).
5. Removes the six `/tmp/liongard_*` settings files and `/tmp/temporary-liongard-values.txt` if an earlier install left them.
6. Checks what's left and lists it.

Tested on macOS 26.7.1 (Apple Silicon) with agent 5.5.0. Intel Macs haven't been tested yet.

It never touches the agent identity `/etc/liongard-agent/.machine-guid`, so a reinstall re-attaches to the same platform record. Delete that folder by hand only if the Mac should register as a new agent, for example before capturing a golden image. Platform removal isn't included.

## Upgrades

When the agent is already running, the script downloads and checks the package as usual, then reads the agent version the package installs.

- **The package is newer:** the script logs `Upgrading the Liongard Agent from <old> to <new>`, installs the package, sets `AGENT_VERSION` in `/Library/Liongard/.config.json` to the new version (as the agent's own updater does), restarts the agent and confirms it's running. The existing registration is kept: the package skips registration because the agent config exists, and the script doesn't write the settings handoff files, so `INSTANCE_URL`, the install token, `NAME`, `ENVIRONMENT` and `AGENT_DESCRIPTION` aren't used.
- **The package is the same version or older, or its version can't be read:** the script exits `0` without changes. It never downgrades the agent.

The installed version must be older than the package in both the agent config and, when the script can find it, the version built into `/Library/Liongard/LiongardAgent`. Rosetta 2 is installed only when an install or upgrade actually happens.

If the agent is installed but not running, the script installs the package over the existing config, whatever its version, and the existing registration is kept.

## Requirements

- Run as **root**.
- The uninstall script needs only root: no tokens, no network access and no settings. The rest of this section applies to the install script.
- macOS on Intel or Apple Silicon.
- HTTPS access to `agents.static.liongard.com`, unless you use `PKG_PATH`.
- An agent install token.

## Settings

These are the install script's settings. The uninstall script has none. Set them in the Variables block at the top of the install script.

### Required

The script ships with `REPLACE_WITH_*` placeholders for these. For a new install, it stops with exit code `1` if any of them is blank or still a placeholder, and names the missing values. If `/Library/Liongard/.config.json` already exists, they aren't needed.

| Setting | Notes |
|---|---|
| `INSTANCE_URL` | Your instance: `us1`, `us1.app.liongard.com` or `https://us1.app.liongard.com` (any case; `http://`, a trailing slash or path and surrounding spaces are fine). The script passes it to the package as `us1.app.liongard.com`. It stops with exit code `1` if the value contains `?`, `*`, `[` or `]`, or isn't a Liongard instance. |
| `ACCESS_KEY_ID`, `ACCESS_KEY_SECRET` | Agent install token. |

### Optional

| Setting | Default | What it does |
|---|---|---|
| `NAME` | The Mac's hostname | Agent name. |
| `ENVIRONMENT` | None | Environment name. It must match the name in Liongard exactly. Blank registers the agent without an environment. If it doesn't exist in Liongard, the agent is installed without one. See [Missing environment](#missing-environment). |
| `AGENT_DESCRIPTION` | None | Agent description. Needs agent package 5.5.0 or newer. |
| `MAC_ARCHITECTURE` | `auto` | `auto` picks the package for the Mac's CPU. `x64` or `arm64` forces one. Ignored when `PKG_PATH` is set, because the package's own architecture is used. |
| `PKG_PATH` | None | Full path to a `.pkg` already on the Mac, for example one your MDM staged. The script installs it instead of downloading. |

`NAME`, `ENVIRONMENT` and `AGENT_DESCRIPTION` are blank by default. Leave them blank if you don't use them: the script stops with exit code `1` if one starts with `REPLACE_WITH_`. They apply only to a new install. The package skips registration when `/Library/Liongard/.config.json` already exists, so changing them and running the script again doesn't change an existing agent.

### Missing environment

If `ENVIRONMENT` names an environment that doesn't exist in Liongard, registration fails and `installer` exits non-zero. A failed registration leaves no agent config behind, so the script can safely try again: when the package log (`/tmp/liongard-agent-installer.log`) says the environment doesn't exist, it hands the settings to the package again without `ENVIRONMENT` and runs `installer` once more. Any other failure is reported as before.

The script logs a WARN before the second attempt and again at the end: `Environment '<name>' was not found in Liongard. The agent was installed without an environment; assign it in Liongard.` Assign the agent to its environment in Liongard afterwards.

The exact registration error for a missing environment isn't confirmed yet. The script looks for a line like "environment ... does not exist" in the package log; the pattern will be tightened once the real message is known.

## Running through an RMM or MDM

- **Run as root.** For example: `sudo ./LGAgentInstall-macOS.sh` or `sudo ./LGAgentUninstall-macOS.sh`.
- **Passing values:** the script reads its settings only from the Variables block, so fill them in there. To use your MDM's or RMM's variables, set them in the block, for example `ENVIRONMENT="$LIONGARD_ENVIRONMENT"` if your tool exports it as an environment variable. Native support for `LIONGARD_*` environment variables is planned in [#10](https://github.com/liongard/agent-scripts/issues/10).
- **Timeouts:** allow several minutes for the download, the Rosetta install if it's needed, and the agent start. The package is downloaded on every run where the installed version can be read, including when the agent is already up to date, because its version is only known after the download.
- **Check the exit code**, not just the tool's "completed" status. See [Exit codes](#exit-codes).

### Notes for specific tools

- **Jamf Pro:** policy scripts run as root. Jamf passes script parameters as `$4` to `$11`, but this script doesn't read them, so set the values in the Variables block.
- **Microsoft Intune** (macOS shell scripts): set **Run script as signed-in user** to **No**, so the script runs as root. Fill in the values in the Variables block before you upload.
- **Addigy, Kandji:** follow the general guidance above: run as root, and set the values in the Variables block.

## Exit codes

Current behavior. Standard exit codes across all scripts are planned in [#11](https://github.com/liongard/agent-scripts/issues/11).

**Uninstall script** (the same as the Windows uninstall scripts):

| Code | Meaning |
|---|---|
| `0` | The agent was removed and nothing is left, or no agent was installed. |
| `1` | Something is still detected afterwards (the script lists it), or the script isn't run as root. |

**Install script:**

| Code | Meaning |
|---|---|
| `0` | The agent is installed and running: newly installed, upgraded, or already running at the same or a newer version. |
| `installer` exit code | `installer` failed. |
| `1` | Any other failure: not root, a missing required value, a failed download or package check, or the agent not running (or not restarting) after the install or upgrade. |

## Logs and files

- **Script output:** goes to stdout and stderr for your RMM or MDM.
- **Package log:** `/tmp/liongard-agent-installer.log`, created root-only by the install script. The uninstall script keeps it.
- **macOS installer log:** `/var/log/install.log`.
- **Settings handoff:** the package reads its settings from six files in `/tmp`: `liongard_instance_url`, `liongard_access_key_id`, `liongard_access_key_secret`, `liongard_name`, `liongard_environment` and `liongard_description`. Before writing them, the script deletes all six, so a blank setting can't pick up a value from an earlier run. It refuses to run if any of them is a symlink or isn't owned by root, writes them as `root:wheel` with mode `600`, and deletes them when it exits. It also removes leftover installer files from earlier runs.

Logs can contain sensitive details, so check them before you share them.

## Troubleshooting

| Message or symptom | What to do |
|---|---|
| `run this script as root` | Run it as root. |
| `<settings> must be set for a new install` | Fill in the named settings, replacing the `REPLACE_WITH_*` placeholders. |
| `INSTANCE_URL '<value>' contains a placeholder character` or `is not a Liongard instance` | Set `INSTANCE_URL` to your instance, for example `us1.app.liongard.com`. |
| `<setting> is still set to a REPLACE_WITH_* placeholder` | Set a value for that optional setting or leave it blank. |
| The script exits `0`, but the name, environment or description didn't change | Expected. Settings apply only to a new install. See [Settings](#settings). |
| The script exits `0` with `already installed and running`, but didn't upgrade | The package isn't newer than the installed agent, or a version couldn't be read. The log line `Package version: ...` shows what was compared. See [Upgrades](#upgrades). |
| `the upgrade was installed, but the agent could not be restarted` | Check `sudo launchctl print system/com.liongard.liongard-agent`, then restart it with `sudo launchctl kickstart -k system/com.liongard.liongard-agent`. |
| The download or the size, signature or architecture check fails | Check HTTPS access to `agents.static.liongard.com`, or check the package at `PKG_PATH`. Don't install a package that fails the signature check. |
| Rosetta 2 install fails on Apple Silicon | Leave `MAC_ARCHITECTURE=auto` to use the Apple Silicon package, which doesn't need Rosetta. |
| `the installer exited with <code>` | Read `/tmp/liongard-agent-installer.log` and `/var/log/install.log`. |
| `the Liongard Agent is still detected` (uninstall, exit `1`) | The lines after it list what's left. Check that your MDM isn't reinstalling the agent, then run the script again. |
| `/Library/Liongard/uninstall.sh isn't a root-owned file ...` (uninstall) | The script skipped the package's own uninstall script and removed the agent itself. Check who changed the file. |
| `/Library/Liongard is a symlink or can be changed by users other than root ...` (uninstall) | The script skipped the package's own uninstall script and removed the agent itself. Check who changed the folder. |
| `Environment '<name>' was not found in Liongard. The agent was installed without an environment` | The agent is installed. Assign it to its environment in Liongard, and fix `ENVIRONMENT` for future installs. |
| `the retry without environment '<name>' failed too` | Registration failed for another reason as well. Read `/tmp/liongard-agent-installer.log`. |
| `the installer succeeded, but the agent isn't running` | Check `sudo launchctl print system/com.liongard.liongard-agent` and the package log. |

For anything else, contact Liongard Partner Support with the logs above.
