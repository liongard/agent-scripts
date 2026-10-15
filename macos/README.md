# macOS

`LGAgentInstall-macOS.sh` installs the Liongard Agent on macOS.

- **Source:** imported from the Liongard docs (https://docs.liongard.com/docs/macos-mass-deployment), then changed to harden the `/tmp` credential handoff (#19). The docs-site copy hasn't been updated yet.
- **Requirements:** run it as **root**. `Liongard-lts.pkg` from https://agents.static.liongard.com/Liongard-lts.pkg must be in the same working directory, because the script runs `installer -pkg Liongard-lts.pkg -target /` and doesn't download the package itself.
- **Credential handoff:** the `.pkg` reads its settings from five files in `/tmp` (`liongard_instance_url`, `liongard_access_key_id`, `liongard_access_key_secret`, `liongard_name`, `liongard_environment`). The script refuses to run if any of them is a symlink or isn't owned by root, writes them as `root:wheel` with mode `600`, and deletes them when it exits.
- **Exit code:** the `installer` exit code, or `1` if a check fails before the install.
- **Required variables:** `INSTANCE_URL` (e.g. `us1.app.liongard.com`), `ACCESS_KEY_ID`, `ACCESS_KEY_SECRET`.
- **Optional variables:** `NAME` (defaults to the hostname) and `ENVIRONMENT` (must match the platform name exactly).

```
sudo ./LGAgentInstall-macOS.sh
```
