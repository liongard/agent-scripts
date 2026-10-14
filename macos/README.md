# macOS

`LGAgentInstall-macOS.sh` installs the Liongard Agent on macOS.

- **Source:** imported unchanged from the Liongard docs: https://docs.liongard.com/docs/macos-mass-deployment
- **Requirements:** run it as **root**. `Liongard-lts.pkg` from https://agents.static.liongard.com/Liongard-lts.pkg must be in the same working directory, because the script runs `installer -pkg Liongard-lts.pkg -target /` and doesn't download the package itself.
- **Required variables:** `INSTANCE_URL` (e.g. `us1.app.liongard.com`), `ACCESS_KEY_ID`, `ACCESS_KEY_SECRET`.
- **Optional variables:** `NAME` (defaults to the hostname) and `ENVIRONMENT` (must match the platform name exactly).

```
sudo ./LGAgentInstall-macOS.sh
```
