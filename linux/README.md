# Linux

Six Bash scripts that install, repair or remove the Liongard Agent on Linux, and save or restore its identity. For other platforms, the behavior matrix and what you need before you start, see the [main README](../README.md).

## Scripts

| Script | What it does | Use it when |
|---|---|---|
| `LGAgentInstall-Linux-Simple.sh` | Installs the agent, or upgrades it when the installer is newer. No Liongard API calls. Never removes an agent. | Standard installs and upgrades. |
| `LGAgentInstall-Linux-Advanced.sh` | Like Simple, but first checks the environment name through the Liongard API and registers the agent under the platform's spelling. | You want the environment name checked before the agent registers. |
| `LGAgentCleanInstall-Linux-Simple.sh` | Repairs a Stale agent: saves its identity, removes it locally and reinstalls it. A Healthy agent is only upgraded when the installer is newer. | The agent is stopped, half removed, or was deleted in the Liongard UI but is still installed. |
| `LGAgentUninstall-Linux-Simple.sh` | Saves the agent identity, then removes the agent. Keeps the platform record. No API calls. | Removing the agent. |
| `LGAgentUninstall-Linux-Advanced.sh` | Like Uninstall Simple, then optionally deletes the agent's platform record. | Decommissioning a host for good. |
| `LGAgentIdentity-Linux.sh` | `backup` saves the agent identity to a folder, `restore --from <folder>` writes it back before a reinstall, and `show` prints it. `backup` also copies the agent config, which holds the agent's keys, unless you pass `--id-only`. | Rebuilding or reimaging a host that must come back as the same agent. |

`LGAgentInstall-Linux.sh` is gone. It was split into the Simple and Advanced install scripts and the two uninstall scripts. Its pre-uninstall, machine-ID collision check (the `DEVICEID` override) and `API_FAILURE_BEHAVIOR` are not carried over: a Stale agent now goes to Clean Install, and `DEVICE_GUID` sets an identity explicitly when you need one.

### Install states

- **Healthy:** the `liongard-agent` unit is registered, `/opt/liongard/LiongardAgent` and `/opt/liongard/.config` exist, and `systemctl is-active liongard-agent` succeeds.
- **Stale:** anything else that leaves a trace: a unit, a package, a process running from `/opt/liongard`, a legacy binary or an agent folder. Clean Install also counts an agent as Stale when the last 3 heartbeat lines in `/opt/liongard/logs/agent.log` all carry `"status_code":401`.
- **NotInstalled:** none of those.

`/etc/liongard-agent` (the agent identity) and the script logs never count, and no script removes them.

## Requirements

- Run as **root** (or with `sudo`), with Bash.
- `curl` or `wget` for the download. `curl` and `jq` for Install Advanced and for Uninstall Advanced with `REMOVE_AGENT_FROM_PLATFORM=true`.
- systemd.
- HTTPS access to `agents.static.liongard.com` and to your instance (`<prefix>.app.liongard.com`).
- An agent install token. An API token for the Advanced scripts.

## Settings

Set these in the configuration block at the top of the script. A required value that is blank or still `REPLACE_WITH_*` stops the script with exit `2`.

### Install scripts (Simple, Advanced, Clean Install)

| Setting | Default | What it does |
|---|---|---|
| `INSTANCE_PREFIX` | `REPLACE_WITH_INSTANCE_PREFIX` | Required. Your instance: `us1`, `us1.app.liongard.com` or `https://us1.app.liongard.com`. |
| `API_TOKEN_KEY`, `API_TOKEN_SECRET` | `REPLACE_WITH_*` | Advanced only, required. Liongard API token for the environment check. |
| `AGENT_TOKEN_KEY`, `AGENT_TOKEN_SECRET` | `REPLACE_WITH_*` | Required. Agent install token (`-k`, `-s`). |
| `ENVIRONMENT` | `REPLACE_WITH_ENVIRONMENT_NAME` | Environment (`-e`). Required when `INCLUDE_ENVIRONMENT_VALUE=true`. |
| `INCLUDE_ENVIRONMENT_VALUE` | `true` | `false` registers the agent without an environment. |
| `AGENT_NAME` | `""` | Agent name (`-n`). Blank uses `hostname`. |
| `AGENT_DESCRIPTION` | `""` | Description (`-d`). Installer 5.5.0 or later. |
| `PROXY_URL` | `""` | Proxy for the agent (`-p`). Credentials are masked in the log. `.run` and `.sh` only. |
| `DEVICE_GUID` | `""` | Identity to use on a fresh install (`-g`); an existing identity wins. Installer 5.4.0 or later. `.run` and `.sh` only. |
| `RESET_IDENTITY` | `false` | `true` passes `--reset-identity`: the agent enrols as a new agent. Installer 5.5.0 or later. `.run` and `.sh` only. |
| `LINUX_ARCHITECTURE` | `auto` | `auto` picks x64 or arm64 from `uname -m`; `x64` or `arm64` forces one. |
| `INSTALLER_URL` | `""` | Blank uses the LTS `.run` for the architecture. A `.deb` or `.rpm` URL installs through `dpkg` or `rpm` with `LIONGARD*` environment variables. |
| `INSTALLER_FILE_NAME` | `""` | Name of the downloaded file. Blank takes it from the URL. |
| `LOG_DIRECTORY` | `/var/log/liongard-agent` | Root-only folder for the script log and the identity backup. |

Removed settings: `ENABLE_PRE_UNINSTALL`, `ENABLE_ENVIRONMENT_MATCHING`, `REMOVE_AGENT_FROM_PLATFORM` (moved to Uninstall Advanced), `DOWNLOAD_DIRECTORY`, `MINIMUM_REMOTE_DELETION_SCORE`, `SERVICE_NAMES`, `DEVICE_ID_OVERRIDE_ARG_NAME`, `API_FAILURE_BEHAVIOR`, `MINIMUM_INSTALLER_BYTES` and `MAX_DOWNLOAD_ATTEMPTS`.

### Uninstall scripts

| Setting | Scripts | Default | What it does |
|---|---|---|---|
| `REMOVE_AGENT_FROM_PLATFORM` | Advanced | `false` | `true` deletes the platform record after the local removal succeeds. |
| `INSTANCE_PREFIX`, `API_TOKEN_KEY`, `API_TOKEN_SECRET` | Advanced | `REPLACE_WITH_*` | Required when `REMOVE_AGENT_FROM_PLATFORM=true`. Checked before anything is removed. |
| `ENVIRONMENT` | Advanced | `""` | The environment the agent is in. Blank matches only an agent with no environment. |
| `LOG_DIRECTORY` | Both | `/var/log/liongard-agent` | Root-only folder for the log and the identity backup. |

## What each script does

**Install Simple and Advanced:** check settings and tools → state (Stale exits `8`) → environment check (Advanced; exit `4`) → download to a private `mktemp -d` folder (exit `5`) → version gate when Healthy (installed `AGENT_VERSION` against the installer's `version.txt`, `.deb` or `.rpm` version; unreadable exits `5`, not newer exits `0`) → install (exit `6`) → validate: service active within 60 seconds and `liongard-agent-updater.timer` present (exit `7`).

**Clean Install:** waits up to 2 minutes while `liongard-agent-updater.service` runs (exit `11`), gives a stopped agent one `systemctl start`, then classifies. Healthy follows the version gate. Stale or NotInstalled: saves the identity (exit `12` on failure), and for Stale removes the agent, checks nothing is left (exit `9`) and, when the identity lived only in the config, writes it to `/etc/liongard-agent/.machine-guid` so the reinstall keeps it. Then installs and validates.

**Uninstall Simple:** saves the identity (exit `12` on failure, nothing removed), stops and disables the units, removes packages, runs any uninstall script, stops processes, removes unit files, legacy binaries and agent folders, then checks nothing is left (exit `9`).

**Uninstall Advanced:** checks the platform settings first, does everything Uninstall Simple does, then removes the platform record (exit `10` on failure).

## Removing the platform record

With `REMOVE_AGENT_FROM_PLATFORM=true`, after the local removal:

1. **AgentID** from `/opt/liongard/.config`. The record must match a local name or `ENVIRONMENT`, and its MachineGuid, when set, must match a local identifier. A MachineGuid that matches only `/etc/machine-id` also needs a local name match.
2. **MachineGuid:** agent identifiers (`/etc/liongard-agent/.machine-guid`, `MACHINE_GUID` in the config) and OS identifiers (`/etc/machine-id`, `/var/lib/dbus/machine-id`). Each is queried as written and in lowercase, with `MachineGuid = '<value>'` and `MachineGuid like '<value>%'`, because older installers (5.0.6, for example) stored the raw machine-id with its trailing newline. The trimmed value is compared on the client. The record must be in `ENVIRONMENT`; an OS-only match also needs a local name match.
3. **Hostname:** `hostname`, `hostname -s` and `hostname -f` against the record's Hostname, Name and FQDN, in `ENVIRONMENT`. A record whose MachineGuid is set and matches no local identifier is skipped.

Placeholder identifiers (`local`, `uninitialized`, all zeros, no hex digit) are never used. Every candidate is logged with its signals. Nothing is deleted when more than one record qualifies. A failed lookup or delete exits `10`. Each delete is confirmed with a lookup, because the API can time out after the record is gone. No qualifying record logs a warning and exits `0`.

## Running through an RMM or MDM

- **Run as root, with Bash** (not `sh`). For example: `sudo bash LGAgentInstall-Linux-Simple.sh`.
- **Passing values:** set them in the configuration block, for example `ENVIRONMENT="${LIONGARD_ENVIRONMENT}"` if your RMM exports it. Use your RMM's secure variable type for tokens. Native `LIONGARD_*` support is planned in [#10](https://github.com/liongard/agent-scripts/issues/10).
- **Timeouts:** allow several minutes for the download and the service start, and up to 2 more minutes for Clean Install when an update is running.
- **Check the exit code**, not just the RMM's "completed" status.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Success, or nothing to do (Healthy and not older, or nothing to uninstall). |
| `1` | Unexpected error. |
| `2` | A setting is missing, a placeholder, or invalid (including `PROXY_URL`, `DEVICE_GUID` or `RESET_IDENTITY` with a `.deb` or `.rpm`). |
| `3` | Not root, a missing tool, an unsupported CPU, or an unsafe log folder. |
| `4` | Environment check failed (Advanced). |
| `5` | Download or version comparison failed. Nothing was changed. |
| `6` | The installer failed. Its output is in the script log. |
| `7` | The installer finished, but the service isn't active or the updater timer is missing. |
| `8` | The agent is Stale. Nothing was changed. Run Clean Install. |
| `9` | The agent is still detected after the removal. |
| `10` | The platform record wasn't removed (Uninstall Advanced). |
| `11` | An agent update kept running for 2 minutes (Clean Install). |
| `12` | The identity couldn't be saved. Nothing was removed. |

## Logs and files

- **Script log:** `LOG_DIRECTORY/LGAgentScript_<timestamp>.log` for install scripts and `LGAgentUninstall_<timestamp>.log` for uninstall scripts. The folder is `0700`, the log `0600`, and the 5 newest logs of each kind are kept. Keys, secrets and proxy passwords are masked.
- **Identity backup:** `LOG_DIRECTORY/liongard-identity-<host>-<timestamp>/` (folder `0700`, files `0600`), in the format `LGAgentIdentity-Linux.sh restore` reads. It never holds a key or secret.
- **Console:** every log line also goes to stderr.
- **Installer:** downloaded to a private temporary folder that is deleted on exit. The API token reaches `curl` on stdin, never on the command line.

## Troubleshooting

| Message or symptom | What to do |
|---|---|
| `Configuration value [<name>] must be set` (exit `2`) | Fill in the setting. |
| `Run this script as root` (exit `3`) | Run it as root. |
| `The installed agent is broken or not running (Stale)` (exit `8`) | Run `LGAgentCleanInstall-Linux-Simple.sh`. |
| `The environment check failed` (exit `4`) | Read the candidate and known-environment lines in the log. Fix `ENVIRONMENT`, or use Install Simple. |
| `The versions can't be compared` (exit `5`) | The config has no `AGENT_VERSION`, or the installer has no readable version. Use Clean Install, or a standard LTS installer. |
| Exit `7` | Check `systemctl status liongard-agent` and `/opt/liongard/logs/agent.log`. |
| `The platform record was not removed` (exit `10`) | Read the candidate lines. Delete the right record in the Liongard UI, or fix `ENVIRONMENT`, then run Uninstall Advanced again. |

For anything else, contact Liongard Partner Support with the script log.
