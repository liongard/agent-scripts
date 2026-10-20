# macOS

`LGAgentInstall-macOS.sh` installs the Liongard Agent on macOS.

- **Source:** imported from the Liongard docs (https://docs.liongard.com/docs/macos-mass-deployment), then changed to harden the `/tmp` credential handoff (#19) and to download and check the package itself (#20). The docs-site copy hasn't been updated yet.
- **Requirements:** run it as **root**. macOS on Intel or Apple Silicon.
- **Package:** the script picks the package for the Mac's CPU (`sysctl -n hw.optional.arm64`, which is correct even under Rosetta) and downloads it with retries:
  - Intel: https://agents.static.liongard.com/LiongardAgent-lts.pkg
  - Apple Silicon: https://agents.static.liongard.com/LiongardAgent-lts-arm64.pkg

  Set `MAC_ARCHITECTURE` to `x64` or `arm64` to force one. The Intel package is Intel-only, so on Apple Silicon it needs Rosetta 2, which the script installs silently if it's missing. To use a package your MDM has already staged, set `PKG_PATH` to its full path. The script then skips the download, and `MAC_ARCHITECTURE` is ignored because the package's own architecture is used.
- **Checks before installing:** the download size must match the server's `Content-Length`, the package must be at least 20 MB and signed with Liongard's Developer ID Installer certificate (Team ID `KU4C98N3LW`), and its architecture must suit the Mac. SHA-256 verification will be added once `.sha256` files are published (#3).
- **Already installed:** if the agent's LaunchDaemon is present and `launchctl print system/com.liongard.liongard-agent` succeeds, the script logs the installed version, applies no settings and exits `0`.
- **New installs only:** `NAME`, `ENVIRONMENT` and `AGENT_DESCRIPTION` only apply to a new install. The package skips registration when `/Library/Liongard/.config.json` already exists, so changing them and rerunning the script doesn't change an existing agent.
- **Credential handoff:** the `.pkg` reads its settings from six files in `/tmp` (`liongard_instance_url`, `liongard_access_key_id`, `liongard_access_key_secret`, `liongard_name`, `liongard_environment`, `liongard_description`). Before writing, the script deletes all six, so a blank setting can't pick up a value from an earlier run. It refuses to run if any of them is a symlink or isn't owned by root, writes them as `root:wheel` with mode `600`, and deletes them when it exits. It also removes leftover installer files from earlier runs and creates the package's log as a root-only file.
- **Exit code:** `0` when the agent is installed and running (including when it already was), the `installer` exit code if the installer fails, and `1` for any other failure.
- **Logs:** the script's own output goes to stdout and stderr for your RMM or MDM. The package logs to `/tmp/liongard-agent-installer.log` (root-only), and `installer` logs to `/var/log/install.log`.
- **Required variables:** `INSTANCE_URL` (e.g. `us1.app.liongard.com`), `ACCESS_KEY_ID`, `ACCESS_KEY_SECRET`.
- **Optional variables:** `NAME` (defaults to the hostname), `ENVIRONMENT` (must match the platform name exactly), `AGENT_DESCRIPTION` (needs agent 5.5.0 or newer), `MAC_ARCHITECTURE` (`auto`, `x64` or `arm64`; default `auto`), `PKG_PATH`.

```
sudo ./LGAgentInstall-macOS.sh
```
