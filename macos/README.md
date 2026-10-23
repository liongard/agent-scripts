# macOS

Six scripts that install, repair or remove the Liongard Agent on a Mac, and save or restore its identity. For other platforms, the behavior matrix and what you need before you start, see the [main README](../README.md).

## Scripts

| Script | What it does | Use it when |
|---|---|---|
| `LGAgentInstall-macOS-Simple.sh` | Installs the agent, or upgrades a running agent when the package is newer. No Liongard API calls. Never removes an agent. | Standard installs and upgrades. |
| `LGAgentInstall-macOS-Advanced.sh` | Like Simple, but first checks the environment name through the Liongard API and registers the agent under the platform's spelling. | You want the environment name checked before the agent registers. |
| `LGAgentCleanInstall-macOS-Simple.sh` | Repairs a Stale agent: saves its identity, removes it locally and reinstalls it. A Healthy agent is only upgraded when the package is newer. | The agent is stopped, half removed, or was deleted in the Liongard UI but is still installed. |
| `LGAgentUninstall-macOS-Simple.sh` | Saves the agent identity, then removes the agent. Keeps the platform record. No API calls. | Removing the agent. |
| `LGAgentUninstall-macOS-Advanced.sh` | Like Uninstall Simple, then optionally deletes the agent's platform record. | Decommissioning a Mac for good. |
| `LGAgentIdentity-macOS.sh` (zsh) | `backup` saves the agent identity to a folder, `restore --from <folder>` writes it back before a reinstall, and `show` prints it. `backup` also copies `/Library/Liongard/.config.json`, which holds the agent's keys, unless you pass `--id-only`. | Rebuilding or reimaging a Mac that must come back as the same agent. |

Renames: `LGAgentInstall-macOS.sh` is now `LGAgentInstall-macOS-Simple.sh`, and `LGAgentUninstall-macOS.sh` is now `LGAgentUninstall-macOS-Advanced.sh`.

### Install states

- **Healthy:** `/Library/LaunchDaemons/com.liongard.liongard-agent.plist`, `/Library/Liongard/LiongardAgent` and `/Library/Liongard/.config.json` exist, and `launchctl print system/com.liongard.liongard-agent` shows `state = running`.
- **Stale:** anything else that leaves a trace: a loaded job or a plist for the agent or its updater, a process running from `/Library/Liongard`, the folder, or a package receipt. Clean Install also counts an agent as Stale when the last 3 heartbeat lines in `/Library/Liongard/logs/agent.log` all carry `"status_code":401`.
- **NotInstalled:** none of those.

`/etc/liongard-agent` (the agent identity) and the script logs never count, and no script removes them.

## Requirements

- Run as **root**.
- macOS on Intel or Apple Silicon, with `curl`. `jq` for Install Advanced and for Uninstall Advanced with `REMOVE_AGENT_FROM_PLATFORM=true` (recent macOS ships `/usr/bin/jq`).
- HTTPS access to `agents.static.liongard.com` (unless you use `PKG_PATH`) and, for the Advanced scripts, to your instance.
- An agent install token. An API token for the Advanced scripts.

## Settings

Set these in the configuration block at the top of the script. A required value that is blank or still `REPLACE_WITH_*` stops the script with exit `2`. Required values are required for every run, including an upgrade.

### Install scripts (Simple, Advanced, Clean Install)

| Setting | Default | What it does |
|---|---|---|
| `INSTANCE_URL` | `REPLACE_WITH_INSTANCE_URL` | Required. Your instance: `us1`, `us1.app.liongard.com` or `https://us1.app.liongard.com`. |
| `API_TOKEN_KEY`, `API_TOKEN_SECRET` | `REPLACE_WITH_*` | Advanced only, required. Liongard API token for the environment check. |
| `ACCESS_KEY_ID`, `ACCESS_KEY_SECRET` | `REPLACE_WITH_*` | Required. Agent install token. |
| `ENVIRONMENT` | `REPLACE_WITH_ENVIRONMENT_NAME` | Environment. Required when `INCLUDE_ENVIRONMENT_VALUE=true`. |
| `INCLUDE_ENVIRONMENT_VALUE` | `true` | `false` registers the agent without an environment. |
| `NAME` | `""` | Agent name. Blank uses the hostname. |
| `AGENT_DESCRIPTION` | `""` | Description. Package 5.5.0 or later. The `DESCRIPTION` alias is removed; use `AGENT_DESCRIPTION`. |
| `MAC_ARCHITECTURE` | `auto` | `auto` picks the Apple Silicon or Intel package; `x64` or `arm64` forces one. The Intel package on Apple Silicon gets Rosetta 2 installed when missing. |
| `PKG_PATH` | `""` | A `.pkg` already on the Mac, for example staged by your MDM. Blank downloads it. |
| `LOG_DIRECTORY` | `/Library/Logs/LiongardDeploy` | Root-only folder for the script log and the identity backup. |

The package reads only the six handoff values (instance, key, secret, name, environment, description), so the scripts expose those and nothing else: the package takes no proxy or device GUID. `NAME`, `ENVIRONMENT` and `AGENT_DESCRIPTION` apply only to a new install. An upgrade keeps the existing registration.

### Uninstall scripts

| Setting | Scripts | Default | What it does |
|---|---|---|---|
| `REMOVE_AGENT_FROM_PLATFORM` | Advanced | `false` | `true` deletes the platform record after the local removal succeeds. |
| `INSTANCE_URL`, `API_TOKEN_KEY`, `API_TOKEN_SECRET` | Advanced | `REPLACE_WITH_*` | Required when `REMOVE_AGENT_FROM_PLATFORM=true`. Checked before anything is removed. |
| `ENVIRONMENT` | Advanced | `""` | The environment the agent is in. Blank matches only an agent with no environment. |
| `LOG_DIRECTORY` | Both | `/Library/Logs/LiongardDeploy` | Root-only folder for the log and the identity backup. |

## What each script does

**Install Simple and Advanced:** check settings → state (Stale exits `8`) → environment check (Advanced; exit `4`) → clear the handoff files and the installer UI's values file → download (or copy `PKG_PATH`) and check size, Liongard signature (Team ID `KU4C98N3LW`) and architecture (exit `5`) → version gate when Healthy (the package version comes from the component's `postinstall` `VERSION=` line; the installed version is the higher of `AGENT_VERSION` and the binary's built-in version; unreadable exits `5`, not newer exits `0`) → install with `installer` (exit `6`) → validate: agent running within 30 seconds and the updater LaunchDaemon present (exit `7`).

An upgrade of a running agent writes no handoff files. The package leaves the old binary running and keeps `AGENT_VERSION`, so the script sets `AGENT_VERSION` to the new version and restarts the agent with `launchctl kickstart -k`, as the agent's own updater does.

**Clean Install:** waits up to 2 minutes while the updater LaunchDaemon runs (exit `11`), gives a stopped agent one start, then classifies. Healthy follows the version gate. Stale or NotInstalled: saves the identity (exit `12` on failure), and for Stale removes the agent, checks nothing is left (exit `9`) and, when the identity lived only in the config, writes it to `/etc/liongard-agent/.machine-guid` so the reinstall keeps it. Then installs and validates.

**Uninstall Simple:** saves the identity (exit `12` on failure, nothing removed), runs `/Library/Liongard/uninstall.sh` only when root owns it and only root can change it, stops and removes both LaunchDaemons, stops leftover processes, removes `/Library/Liongard` and both package receipts, deletes the `/tmp` handoff files, then checks nothing is left (exit `9`).

**Uninstall Advanced:** checks the platform settings first, does everything Uninstall Simple does, then removes the platform record (exit `10` on failure).

## Removing the platform record

With `REMOVE_AGENT_FROM_PLATFORM=true`, after the local removal:

1. **AgentID** from `/Library/Liongard/.config.json`. The record must match a local name or `ENVIRONMENT`, and its MachineGuid, when set, must match a local identifier. A MachineGuid that matches only the IOPlatformUUID also needs a local name match.
2. **MachineGuid:** agent identifiers (`/etc/liongard-agent/.machine-guid`, `MACHINE_GUID` in the config) and the OS identifier (IOPlatformUUID). Each is queried as written and in lowercase, with `=` and `like`, and the trimmed value is compared on the client. The record must be in `ENVIRONMENT`; an OS-only match also needs a local name match.
3. **Hostname:** `hostname`, `hostname -s` and `LocalHostName` against the record's Hostname, Name and FQDN, in `ENVIRONMENT`. A record whose MachineGuid is set and matches no local identifier is skipped.

Placeholder identifiers are never used. Every candidate is logged with its signals. Nothing is deleted when more than one record qualifies. A failed lookup or delete exits `10`. Each delete is confirmed with a lookup. No qualifying record logs a warning and exits `0`.

## Running through an RMM or MDM

- **Run as root.** For example: `sudo bash LGAgentInstall-macOS-Simple.sh`.
- **Passing values:** set them in the configuration block, for example `ENVIRONMENT="$LIONGARD_ENVIRONMENT"`. Native `LIONGARD_*` support is planned in [#10](https://github.com/liongard/agent-scripts/issues/10).
- **Jamf Pro:** policy scripts run as root. The scripts don't read `$4` to `$11`, so set the values in the configuration block.
- **Microsoft Intune** (macOS shell scripts): set **Run script as signed-in user** to **No**.
- **Timeouts:** allow several minutes for the download, a Rosetta install and the agent start.
- **Check the exit code**, not just the tool's "completed" status.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Success, or nothing to do. |
| `1` | Unexpected error. |
| `2` | A setting is missing, a placeholder, or invalid (including `MAC_ARCHITECTURE=arm64` on an Intel Mac). |
| `3` | Not root, a missing tool, Rosetta 2 couldn't be installed, an unsafe handoff, values or log file. |
| `4` | Environment check failed (Advanced). |
| `5` | Download, size, signature, architecture or version check failed. Nothing was changed. |
| `6` | `installer` failed. Its output is in the script log; see also `/tmp/liongard-agent-installer.log` and `/var/log/install.log`. |
| `7` | The install finished, but the agent isn't running, couldn't be restarted after an upgrade, or the updater LaunchDaemon is missing. |
| `8` | The agent is Stale. Nothing was changed. Run Clean Install. |
| `9` | The agent is still detected after the removal. |
| `10` | The platform record wasn't removed (Uninstall Advanced). |
| `11` | An agent update kept running for 2 minutes (Clean Install). |
| `12` | The identity couldn't be saved. Nothing was removed. |

## Logs and files

- **Script log:** `LOG_DIRECTORY/LGAgentScript_<timestamp>.log` or `LGAgentUninstall_<timestamp>.log` (folder `0700`, log `0600`, 5 newest kept), with keys and secrets masked. The `installer` output is logged through the same masking.
- **Identity backup:** `LOG_DIRECTORY/liongard-identity-<host>-<timestamp>/`, in the format `LGAgentIdentity-macOS.sh restore` reads. It never holds a key or secret.
- **Package log:** `/tmp/liongard-agent-installer.log`, created root-only by the script. **macOS installer log:** `/var/log/install.log`.
- **Settings handoff:** `/tmp/liongard_instance_url`, `liongard_access_key_id`, `liongard_access_key_secret`, `liongard_name`, `liongard_environment` and `liongard_description`. The script deletes all six first (refusing symlinks and files not owned by root), writes them `root:wheel` `600`, and deletes them on exit, including on INT and TERM.

## Troubleshooting

| Message or symptom | What to do |
|---|---|
| `Configuration value [<name>] must be set` (exit `2`) | Fill in the setting. |
| `The installed agent is broken or not running (Stale)` (exit `8`) | Run `LGAgentCleanInstall-macOS-Simple.sh`. |
| The signature or architecture check fails (exit `5`) | Check the package at `PKG_PATH` or HTTPS access to `agents.static.liongard.com`. Don't install a package that fails the signature check. |
| `The versions can't be compared` (exit `5`) | The config has no `AGENT_VERSION` or the package has no readable version. Use Clean Install. |
| Exit `7` | Check `sudo launchctl print system/com.liongard.liongard-agent` and `/Library/Liongard/logs/agent.log`. |
| `The platform record was not removed` (exit `10`) | Read the candidate lines. Delete the right record in the Liongard UI, or fix `ENVIRONMENT`, then run Uninstall Advanced again. |

For anything else, contact Liongard Partner Support with the logs above.
