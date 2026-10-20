# macOS

`LGAgentInstall-macOS.sh` installs the Liongard Agent on macOS. For other platforms, and for what you need before you start, see the [main README](../README.md).

## Script

| Script | What it does | Use it when |
|---|---|---|
| `LGAgentInstall-macOS.sh` | Downloads and checks the agent package for the Mac's CPU (or uses one your MDM staged), hands it your settings and installs it. | Installing the agent on a Mac with Intel or Apple Silicon. |

What it does, in order:

1. **If the agent is already installed and running, it exits `0` without changes.** It logs the installed version and applies no settings, and it doesn't upgrade the agent.
2. Picks the package for the Mac's CPU, using `sysctl -n hw.optional.arm64`, which is correct even under Rosetta:
   - Intel: `https://agents.static.liongard.com/LiongardAgent-lts.pkg`
   - Apple Silicon: `https://agents.static.liongard.com/LiongardAgent-lts-arm64.pkg`

   It downloads the package with retries, unless `PKG_PATH` points to one already on the Mac.
3. Checks the package before installing. The download size must match the server's `Content-Length`, and the package must be at least 20 MB, signed with Liongard's Developer ID Installer certificate (Team ID `KU4C98N3LW`), and built for this Mac. SHA-256 checks will be added once checksum files are published ([#3](https://github.com/liongard/agent-scripts/issues/3)).
4. Installs Rosetta 2 silently if the Intel package is used on Apple Silicon and Rosetta is missing.
5. Hands your settings to the package (see [Logs and files](#logs-and-files)), runs `installer`, and confirms the agent is running.

## Requirements

- Run as **root**.
- macOS on Intel or Apple Silicon.
- HTTPS access to `agents.static.liongard.com`, unless you use `PKG_PATH`.
- An agent install token.

## Settings

Set these in the Variables block at the top of the script.

### Required

For a new install, the script stops if any of these is blank.

| Setting | Notes |
|---|---|
| `INSTANCE_URL` | Your instance address, for example `us1.app.liongard.com`. |
| `ACCESS_KEY_ID`, `ACCESS_KEY_SECRET` | Agent install token. |

### Optional

| Setting | Default | What it does |
|---|---|---|
| `NAME` | The Mac's hostname | Agent name. |
| `ENVIRONMENT` | None | Environment name. It must match the name in Liongard exactly. Blank registers the agent without an environment. |
| `AGENT_DESCRIPTION` | None | Agent description. Needs agent package 5.5.0 or newer. |
| `MAC_ARCHITECTURE` | `auto` | `auto` picks the package for the Mac's CPU. `x64` or `arm64` forces one. Ignored when `PKG_PATH` is set, because the package's own architecture is used. |
| `PKG_PATH` | None | Full path to a `.pkg` already on the Mac, for example one your MDM staged. The script installs it instead of downloading. |

`NAME`, `ENVIRONMENT` and `AGENT_DESCRIPTION` apply only to a new install. The package skips registration when `/Library/Liongard/.config.json` already exists, so changing them and running the script again doesn't change an existing agent.

## Running through an RMM or MDM

- **Run as root.** For example: `sudo ./LGAgentInstall-macOS.sh`.
- **Passing values:** the script reads its settings only from the Variables block, so fill them in there. To use your MDM's or RMM's variables, set them in the block, for example `ENVIRONMENT="$LIONGARD_ENVIRONMENT"` if your tool exports it as an environment variable. Native support for `LIONGARD_*` environment variables is planned in [#10](https://github.com/liongard/agent-scripts/issues/10).
- **Timeouts:** allow several minutes for the download, the Rosetta install if it's needed, and the agent start.
- **Check the exit code**, not just the tool's "completed" status. See [Exit codes](#exit-codes).

### Notes for specific tools

- **Jamf Pro:** policy scripts run as root. Jamf passes script parameters as `$4` to `$11`, but this script doesn't read them, so set the values in the Variables block.
- **Microsoft Intune** (macOS shell scripts): set **Run script as signed-in user** to **No**, so the script runs as root. Fill in the values in the Variables block before you upload.
- **Addigy, Kandji:** follow the general guidance above: run as root, and set the values in the Variables block.

## Exit codes

Current behavior. Standard exit codes across all scripts are planned in [#11](https://github.com/liongard/agent-scripts/issues/11).

| Code | Meaning |
|---|---|
| `0` | The agent is installed and running, including when it already was. |
| `installer` exit code | `installer` failed. |
| `1` | Any other failure: not root, a missing required value, a failed download or package check, or the agent not running after the install. |

## Logs and files

- **Script output:** goes to stdout and stderr for your RMM or MDM.
- **Package log:** `/tmp/liongard-agent-installer.log`, created root-only by the script.
- **macOS installer log:** `/var/log/install.log`.
- **Settings handoff:** the package reads its settings from six files in `/tmp`: `liongard_instance_url`, `liongard_access_key_id`, `liongard_access_key_secret`, `liongard_name`, `liongard_environment` and `liongard_description`. Before writing them, the script deletes all six, so a blank setting can't pick up a value from an earlier run. It refuses to run if any of them is a symlink or isn't owned by root, writes them as `root:wheel` with mode `600`, and deletes them when it exits. It also removes leftover installer files from earlier runs.

Logs can contain sensitive details, so check them before you share them.

## Troubleshooting

| Message or symptom | What to do |
|---|---|
| `run this script as root` | Run it as root. |
| `INSTANCE_URL, ACCESS_KEY_ID and ACCESS_KEY_SECRET are required for a new install` | Fill in the required settings. |
| The script exits `0`, but the name, environment or description didn't change | Expected. Settings apply only to a new install. See [Settings](#settings). |
| The download or the size, signature or architecture check fails | Check HTTPS access to `agents.static.liongard.com`, or check the package at `PKG_PATH`. Don't install a package that fails the signature check. |
| Rosetta 2 install fails on Apple Silicon | Leave `MAC_ARCHITECTURE=auto` to use the Apple Silicon package, which doesn't need Rosetta. |
| `the installer exited with <code>` | Read `/tmp/liongard-agent-installer.log` and `/var/log/install.log`. |
| `the installer succeeded, but the agent isn't running` | Check `sudo launchctl print system/com.liongard.liongard-agent` and the package log. |

For anything else, contact Liongard Partner Support with the logs above.
