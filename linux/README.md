# Linux

`LGAgentInstall-Linux.sh` installs the Liongard Agent on Linux, and `LGAgentUninstall-Linux.sh` removes it. For other platforms, and for what you need before you start, see the [main README](../README.md).

## Scripts

| Script | What it does | Use it when |
|---|---|---|
| `LGAgentInstall-Linux.sh` | Removes any existing agent (by default), matches the environment name and checks for machine-ID collisions through the Liongard API, then downloads, installs and validates the agent. | Installing or reinstalling the agent on a Linux endpoint. |
| `LGAgentUninstall-Linux.sh` | Removes the agent from the endpoint: services and updater timer, package, processes, unit files, binaries and install folders. No Liongard API calls and no settings to fill in. The agent's record stays on the platform. | Removing the agent from a Linux endpoint. |

What the install script does, in order:

1. Checks the configuration and prerequisites, and picks the x64 or arm64 installer from `uname -m`.
2. **Removes any existing Liongard Agent by default** (`ENABLE_PRE_UNINSTALL=true`), including leftover install folders and config files. With `ENABLE_PRE_UNINSTALL=false`, an installed agent is left as it is, and the script exits `0`. The agent's platform record is kept unless `REMOVE_AGENT_FROM_PLATFORM=true`.
3. Matches the environment name against your instance (`ENABLE_ENVIRONMENT_MATCHING=true` by default) and stops if no environment matches.
4. Looks up the machine ID in Liongard. If it's already registered under a different hostname, the script gives the new agent its own device ID, so it doesn't overwrite the other record.
5. Downloads the installer to a private temporary folder, which is deleted when the script exits, and installs it with the package manager (`.deb`, `.rpm`) or the installer itself (`.run`, `.sh`).
6. Confirms the agent service is running.

What the uninstall script does, in order:

1. Stops and disables the agent service and the updater timer (`liongard-agent`, `liongard-agent-updater` and the older names the install script also looks for).
2. Removes any installed `.deb` or `.rpm` Liongard package with the package manager (`remove`, not `purge`). A package that's only left as config (`rc`) doesn't count as installed.
3. Stops leftover agent processes, including those running from `/opt/liongard`.
4. Removes the unit files, runs the agent's own uninstall script if one exists, and removes the agent binaries and install folders (`/opt/liongard`, `/opt/liongard-agent`, `/usr/local/liongard`).
5. Checks what's left and lists it.

It never touches the agent identity `/etc/liongard-agent/.machine-guid`, so a reinstall re-attaches to the same platform record, or the log folders. It leaves `/etc/liongard` in place with a warning until the dev team confirms what it holds. Platform removal isn't included.

## Requirements

- Run as **root** (or with `sudo`).
- The uninstall script needs only root and Bash: no tokens, no network access and no settings. The rest of this section applies to the install script.
- Bash 4.0 or later.
- `curl` or `wget`, plus `sed`, `awk`, `grep` and `hostname`.
- `jq` when environment matching or platform removal is on. Environment matching is on by default.
- HTTPS access to `agents.static.liongard.com` and to your instance (`<prefix>.app.liongard.com`).
- Tested targets: Ubuntu 20.04+, Debian 10+, RHEL/Rocky/Alma 8+, CentOS 7+, Amazon Linux 2, SUSE 15+, Fedora 36+.
- A Liongard API token and an agent install token.

## Settings

These are the install script's settings. The uninstall script has none. The configuration block at the top of the install script has three sections. The script stops with exit code `2` if a required value is blank or a `REPLACE_WITH_*` placeholder.

### A. Required

| Setting | Notes |
|---|---|
| `INSTANCE_PREFIX` | Your instance: `us1`, `us1.app.liongard.com` or `https://us1.app.liongard.com`. Replace the `us?` placeholder. |
| `API_TOKEN_KEY`, `API_TOKEN_SECRET` | Liongard API token, used for environment matching and collision checks. |
| `AGENT_TOKEN_KEY`, `AGENT_TOKEN_SECRET` | Agent install token. |
| `ENVIRONMENT` | Environment name. Required only when `INCLUDE_ENVIRONMENT_VALUE=true`. |

### B. Optional

| Setting | Default | What it does |
|---|---|---|
| `INCLUDE_ENVIRONMENT_VALUE` | `true` | `false` registers the agent without an environment, and `ENVIRONMENT` isn't needed. |
| `ENABLE_ENVIRONMENT_MATCHING` | `true` | Matches `ENVIRONMENT` against your instance and corrects casing or punctuation. `false` uses the value exactly as written. |
| `ENABLE_PRE_UNINSTALL` | `true` | Removes any existing agent before installing. `false` leaves an installed agent as it is. |
| `REMOVE_AGENT_FROM_PLATFORM` | `false` | After a successful pre-uninstall, also deletes the matching agent record from Liongard. Ignored when `ENABLE_PRE_UNINSTALL=false`. |
| `AGENT_DESCRIPTION` | `""` | Agent description, passed only when set. |
| `LOG_DIRECTORY` | `/var/log/liongard-agent` | Where the script log goes. Created root-only when missing. |
| `LINUX_ARCHITECTURE` | `auto` | `auto` picks the installer from `uname -m` (`x86_64` → x64, `aarch64` → arm64). `x64` or `arm64` forces one. |
| `INSTALLER_URL` | `""` | Leave empty to use the LTS installer for the architecture. When set, it's used as-is, `LINUX_ARCHITECTURE` is ignored, and the package type comes from the file extension. |
| `INSTALLER_FILE_NAME` | `""` | Name of the downloaded installer. Empty takes it from the URL. |
| `DOWNLOAD_DIRECTORY` | `""` | Deprecated and no longer used. If set, the script logs a warning and carries on. It will be removed in a later release. |

### C. Advanced

Leave these alone unless Liongard Support asks you to change them.

| Setting | Default | What it does |
|---|---|---|
| `MINIMUM_REMOTE_DELETION_SCORE` | `50` | Minimum match score a platform record needs before `REMOVE_AGENT_FROM_PLATFORM=true` deletes it. |
| `SERVICE_NAMES` | `roaragent liongard-agent liongardagent LiongardAgent` | Service names the script looks for. |
| `DEVICE_ID_OVERRIDE_ARG_NAME` | `DEVICEID` | Installer property for the device ID override. |
| `API_FAILURE_BEHAVIOR` | `conservative` | When the collision check's API call fails: `conservative` stops (exit `4`), `permissive` continues without it. |
| `MINIMUM_INSTALLER_BYTES` | `10240` | Smallest download the script accepts as an installer. |
| `MAX_DOWNLOAD_ATTEMPTS` | `3` | Download attempts before the script gives up. |

## Running through an RMM or MDM

- **Run as root.** For example: `sudo bash LGAgentInstall-Linux.sh` or `sudo bash LGAgentUninstall-Linux.sh`.
- **Run it with Bash**, not `sh`.
- **Passing values with RMM variables:** set the value in the configuration block from the variable your RMM provides, for example `ENVIRONMENT="${LIONGARD_ENVIRONMENT}"` if your RMM exports it as an environment variable. Use your RMM's secure variable type for tokens. Native support for `LIONGARD_*` environment variables is planned in [#10](https://github.com/liongard/agent-scripts/issues/10).
- **Timeouts:** allow several minutes. The script may uninstall an existing agent, makes several API calls, downloads the installer and waits for the service to start.
- **Check the exit code**, not just the RMM's "completed" status. See [Exit codes](#exit-codes).

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
| `0` | Installed and validated, or the agent was already installed and `ENABLE_PRE_UNINSTALL=false`. |
| `1` | Unexpected failure. |
| `2` | A required setting is missing or invalid. |
| `3` | A prerequisite is missing (not root, no `curl` or `wget`, no `jq` when needed, unsupported architecture or installer type). |
| `4` | The environment couldn't be matched, or the collision check's API call failed with `API_FAILURE_BEHAVIOR=conservative`. |
| `5` | The installer download failed. |
| `6` | The install command failed. |
| `7` | The install finished, but validation failed: the agent service isn't running. |
| `8` | The pre-uninstall failed: the agent is still detected afterwards. |

## Logs and files

- **Uninstall script:** writes no log file. Progress goes to stdout, and warnings and errors to stderr, so your RMM's script output shows everything.
- **Script log** (install script): `LOG_DIRECTORY/LGAgentScript_<timestamp>.log` (default `/var/log/liongard-agent`). A missing folder is created with mode `0700`, and the log with mode `0600`.
- **Console:** the same lines go to stderr, so your RMM's script output shows them.
- **Installer:** downloaded to a private temporary folder (`mktemp -d`), which is deleted when the script exits. The API key is passed to `curl` or `wget` without appearing on the command line.

Logs can contain sensitive details, so check them before you share them.

## Troubleshooting

| Message or symptom | What to do |
|---|---|
| `Configuration value [<name>] must be provided` (exit `2`) | A required setting is still blank or a `REPLACE_WITH_*` placeholder. Fill it in. |
| `This script must be run as root or via sudo` (exit `3`) | Run it as root. |
| `Neither curl nor wget is available` or `jq is required ...` (exit `3`) | Install the missing tool, or turn off environment matching and platform removal if you don't need them. |
| `Unsupported CPU architecture` (exit `3`) | Installers exist for x86_64 and aarch64 only. |
| `Environment '<name>' ... could not be resolved in Liongard` (exit `4`) | Check the name and that the environment exists in your instance. Or set `ENABLE_ENVIRONMENT_MATCHING=false` to pass it as written, or `INCLUDE_ENVIRONMENT_VALUE=false` to skip it. |
| `API_FAILURE_BEHAVIOR=conservative. Cannot continue without collision detection` (exit `4`) | The API call failed. Check the API token and HTTPS access to your instance. |
| `Installer download failed` (exit `5`) | Check HTTPS access to `agents.static.liongard.com`, or to your `INSTALLER_URL`. |
| `Installation failed` (exit `6`) | Read the installer output in the script log. On Debian and Ubuntu the script runs `apt-get install -f` after a `dpkg` failure. |
| Validation failed (exit `7`) | The agent service isn't running. Check `systemctl status roaragent` and the script log. |
| `Run this script as root` (uninstall, exit `1`) | Run it as root. |
| `The Liongard Agent is still detected` (uninstall, exit `1`) | The lines after it list what's left. Check that nothing else (a configuration management tool, for example) reinstalls the agent, remove the items by hand, and run the script again. |
| `/etc/liongard was left in place ...` (uninstall) | Not an error. Remove `/etc/liongard` by hand if you don't need it. Never remove `/etc/liongard-agent` unless you want the next install to register as a new agent. |
| `Liongard Agent is still detected after uninstall` (exit `8`) | Remove the existing agent by hand, then run the script again. |

For anything else, contact Liongard Partner Support with the script log.
