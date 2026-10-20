# Liongard Agent Deployment Scripts

> **DRAFT – internal.** Not yet reviewed for public release. Do not share outside Liongard.

Scripts that install, upgrade and remove the Liongard Agent on Windows, Linux and macOS endpoints through your RMM or MDM. Each script is one self-contained file: paste it into your RMM or MDM, fill in the configuration block at the top, and deploy.

## Which script do I use?

| Platform | Situation | Script | Docs |
|---|---|---|---|
| Windows | Standard install or upgrade | `LGAgentInstall-MSI-Simple.ps1` | [Windows](windows/README.md) |
| Windows | Host will run the network discovery inspector (needs Npcap and Visual C++) | `LGAgentInstall-EXE-Simple.ps1` | [Windows](windows/README.md) |
| Windows | You want the environment name checked through the Liongard API and a full transcript log | `LGAgentInstall-MSI-Advanced.ps1` or `LGAgentInstall-EXE-Advanced.ps1` | [Windows](windows/README.md) |
| Windows | Agent is old, broken, partly uninstalled or corrupt | `LGAgentCleanInstall-MSI-Simple.ps1` | [Windows](windows/README.md) |
| Windows | Remove the agent | `LGAgentUninstall.ps1` | [Windows](windows/README.md) |
| Linux | Install (x64 or arm64; `.deb`, `.rpm`, `.run` or `.sh`) | `LGAgentInstall-Linux.sh` | [Linux](linux/README.md) |
| macOS | Install (Intel or Apple Silicon) | `LGAgentInstall-macOS.sh` | [macOS](macos/README.md) |

- **Simple or Advanced (Windows):** Simple scripts make no Liongard API calls and need only an agent install token. Advanced scripts also need an API token, which they use to match the environment name before installing.
- **MSI or EXE (Windows):** the EXE bundle adds Visual C++ and Npcap, which the network discovery inspector needs. Otherwise use the MSI.

## Before you start

You need:

- **Your Liongard instance:** its prefix or address, for example `us1` or `us1.app.liongard.com`.
- **An agent install token** (key and secret). Every install script needs one.
- **An API token** (key and secret) for the Windows Advanced scripts, the Linux script, and the Windows uninstall script when it also removes the agent from the platform.
- **The environment name**, if you assign agents to an environment. It must match the name in Liongard.

Keep tokens in your RMM's or MDM's secure variables or script fields. Don't save them in a copy of the script that other people can read.

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
