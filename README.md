# Liongard Agent Deployment Scripts

> **DRAFT – internal.** Not yet reviewed for public release. Do not share outside Liongard.

Scripts that install, upgrade and remove the Liongard Agent on Windows, Linux and macOS endpoints through your RMM or MDM. Each script is one self-contained file: paste it into your RMM or MDM, fill in the configuration block at the top, and deploy.

## Which script do I use?

Every platform has the same set of scripts. Pick the row for the job, then the column for the platform.

| Job | Windows | Linux | macOS |
|---|---|---|---|
| Install or upgrade, no API calls | `LGAgentInstall-MSI-Simple.ps1` (or `-EXE-Simple` for network discovery hosts) | `LGAgentInstall-Linux-Simple.sh` | `LGAgentInstall-macOS-Simple.sh` |
| Install or upgrade after checking the environment name through the API | `LGAgentInstall-MSI-Advanced.ps1` (or `-EXE-Advanced`) | `LGAgentInstall-Linux-Advanced.sh` | `LGAgentInstall-macOS-Advanced.sh` |
| Repair a broken, stopped or refused agent | `LGAgentCleanInstall-MSI-Simple.ps1` | `LGAgentCleanInstall-Linux-Simple.sh` | `LGAgentCleanInstall-macOS-Simple.sh` |
| Remove the agent, keep the platform record | `LGAgentUninstall-Simple.ps1` | `LGAgentUninstall-Linux-Simple.sh` | `LGAgentUninstall-macOS-Simple.sh` |
| Remove the agent and, optionally, its platform record | `LGAgentUninstall-Advanced.ps1` | `LGAgentUninstall-Linux-Advanced.sh` | `LGAgentUninstall-macOS-Advanced.sh` |
| Save or restore the agent identity before a rebuild | `LGAgentIdentity.ps1` | `LGAgentIdentity-Linux.sh` | `LGAgentIdentity-macOS.sh` |

- **Simple or Advanced:** Simple scripts make no Liongard API calls and need only an agent install token. Advanced scripts also need an API token.
- **MSI or EXE (Windows):** the EXE bundle adds Visual C++ and Npcap, which the network discovery inspector needs. Otherwise use the MSI.

## How the scripts behave

Every script first puts the agent in one of three states. The rules are the same on every OS.

- **Healthy:** installed and the agent service is running.
- **Stale:** installed but broken, stopped, half removed, or (Clean Install only) refused by the platform: its last 3 heartbeats returned HTTP 401, for example after it was deleted in the Liongard UI.
- **NotInstalled:** nothing of the agent is left.

| Script | NotInstalled | Healthy | Stale |
|---|---|---|---|
| Install Simple | Installs. | Upgrades only when the installer is newer, else exits `0`. | Changes nothing, exits `8` and points to Clean Install. |
| Install Advanced | Checks the environment, then installs. | Checks the environment, then upgrades only when newer. | Changes nothing, exits `8`. |
| Clean Install | Saves any identity left behind, then installs. | Upgrades only when newer. Never removes a working agent. | Saves the identity, removes the agent locally, then installs. The agent keeps its identity, so it re-attaches to the same platform record. |
| Uninstall Simple | Exits `0`. | Saves the identity, then removes the agent locally. No API calls. | Same as Healthy. |
| Uninstall Advanced | Same as Simple, then optionally deletes the platform record. | Same. | Same. |

Shared rules:

- **Nothing is removed before the settings, the environment check (Advanced) and the download are done.** A failure there changes nothing.
- **Version gate:** a Healthy agent is upgraded only when the installer is strictly newer. If either version can't be read, the script exits `5` and changes nothing.
- **Environment check (Advanced):** an exact match first, then a case-insensitive one, then a normalized one (letters and digits only, without "The", "&" or "and"), then a prefix or contains match where both normalized names have at least 6 characters. No match, more than one match, or a failed lookup exits `4`.
- **Clean Install** waits up to 2 minutes for a running agent update (exit `11` if it keeps running) and gives a stopped agent one start attempt before it decides.
- **Identity:** no script modifies the agent identity (`HKLM\SOFTWARE\WOW6432Node\Liongard` on Windows, `/etc/liongard-agent` on Linux and macOS). Only the `LGAgentIdentity` scripts write it.
- **Logs** go to a root-only or SYSTEM-only folder, with keys and secrets masked: `%ProgramData%\LiongardDeploy`, `/var/log/liongard-agent`, `/Library/Logs/LiongardDeploy`.
- **Placeholders:** every required value starts as `REPLACE_WITH_...`. A script refuses to run (exit `2`) while one is unset.

OS differences:

| Topic | Windows | Linux | macOS |
|---|---|---|---|
| Installer | MSI or EXE bundle | `.run` (default), `.sh`, `.deb` or `.rpm` | Signed `.pkg`, Intel or Apple Silicon |
| Running check | `roaragent.exe` service Running | `systemctl is-active liongard-agent` | `launchctl print system/com.liongard.liongard-agent` shows `state = running` |
| Heartbeat log for the 401 rule | `AgentSVCLog.txt` | `/opt/liongard/logs/agent.log` | `/Library/Liongard/logs/agent.log` |
| Install validation | Service Running and updater task present | Service active and updater timer present | Agent running and updater LaunchDaemon present |
| Upgrade of a running agent | The installer replaces it | The installer replaces it | The package leaves the old binary running, so the script records the new version and restarts the agent |
| Clean Install variants | MSI only | One script | One script |

## Exit codes

The same table applies to every script on every OS.

| Code | Meaning |
|---|---|
| `0` | Success, or nothing to do. |
| `1` | Unexpected error. |
| `2` | A setting is missing, still a `REPLACE_WITH_*` placeholder, or invalid. |
| `3` | A prerequisite or permission is missing (not root or SYSTEM, a missing tool), or the log or deploy folder is unsafe. |
| `4` | Environment check failed: no match, more than one match, or the lookup failed (Advanced). |
| `5` | Download, package check or version comparison failed. Nothing was changed. |
| `6` | The installer failed. Its own code is in the log. |
| `7` | The installer finished, but the agent isn't running or its updater is missing. |
| `8` | The agent is Stale. Nothing was changed. Run Clean Install. |
| `9` | The agent is still detected after the local removal (Uninstall) or the cleanup (Clean Install). |
| `10` | The agent was removed locally, but the platform record wasn't removed (Uninstall Advanced). |
| `11` | Busy: another installation is running (msiexec `1618`) or an agent update is still running. Try again later. |
| `12` | The agent identity couldn't be saved. Nothing was removed. |

## Before you start

You need:

- **Your Liongard instance:** its prefix or address, for example `us1` or `us1.app.liongard.com`.
- **An agent install token** (key and secret). Every install script needs one.
- **An API token** (key and secret) for the Advanced install scripts, and for Uninstall Advanced when it also removes the platform record.
- **The environment name**, if you assign agents to an environment.

Keep tokens in your RMM's or MDM's secure variables or script fields. Don't save them in a copy of the script that other people can read.

## Removing the platform record

Uninstall Advanced, with `REMOVE_AGENT_FROM_PLATFORM=true` (`$RemoveAgentFromPlatform = $true` on Windows), deletes the agent's record after the local removal succeeds. Every platform uses the same rules:

1. **AgentID** from the agent config. The record must also match a local name (Hostname, Name or FQDN) or the configured environment, and its MachineGuid, when set, must match a local identifier.
2. **MachineGuid:** every local agent identifier, plus the OS identifier (Windows MachineGuid, `/etc/machine-id`, the Mac's IOPlatformUUID). The lookup tries the value as stored and its lowercase form, with `=` and with `like`, and compares the trimmed value on the client. A match on an OS identifier alone also needs a local name match, because cloned machines share it. The record must be in the configured environment.
3. **Hostname:** a record whose Hostname, Name or FQDN equals a local name, in the configured environment, and whose MachineGuid is empty or matches a local identifier.

Placeholder identifiers (`local`, `uninitialized`, all zeros, no hex digit) are never used. Every candidate is logged with its signals. Nothing is deleted when more than one record qualifies, a failed lookup or delete exits `10`, and each delete is confirmed with a follow-up lookup. See each platform README for details.

## Get the scripts

- **Download:** open the script in its folder on GitHub and download it, or copy its contents.
- **Raw link:** `https://raw.githubusercontent.com/liongard/agent-scripts/main/<folder>/<script>`, for example `https://raw.githubusercontent.com/liongard/agent-scripts/main/windows/LGAgentInstall-MSI-Simple.ps1`.

Paste the whole file into your RMM or MDM, and change only the configuration block at the top. Each script's header explains what it does and links to its platform README.

## Security

To report a vulnerability, email **security.ops@liongard.com**. Don't open a GitHub issue. See [SECURITY.md](SECURITY.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Changes are listed in [CHANGELOG.md](CHANGELOG.md).

## Support and license

- **Support:** Liongard Partner Support.
- Licensed under Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
