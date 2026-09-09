<p align="center">
  <img src="docs/assets/icon.png" width="88" alt="Portkeep">
</p>

<h1 align="center">Portkeep</h1>

<p align="center">
  Local runtimes, on this Mac.<br>
  See who owns <code>:3000</code>. Stop the leftover tree.
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-2f7bff?style=flat-square" alt="MIT"></a>
  <a href="https://github.com/Slowper/Portkeep"><img src="https://img.shields.io/badge/macOS-14%2B-black?style=flat-square" alt="macOS 14+"></a>
  <a href="https://github.com/Slowper/Portkeep"><img src="https://img.shields.io/badge/Swift-6-F05138?style=flat-square" alt="Swift 6"></a>
  <img src="https://img.shields.io/badge/menu%20bar-local%20only-1f4d3a?style=flat-square" alt="Menu bar, local only">
</p>

<p align="center">
  <img src="docs/assets/banner.png" alt="Portkeep — local runtimes, on this Mac">
</p>

Portkeep is a macOS menu bar app for leftover localhost ports. It shows what is listening, which project it belongs to, and whether a human, Cursor, or Claude Code started it. Stop the whole process tree. Reserve a stable port per worktree. Give agents a CLI and MCP.

**Yours, with no catch.** Ports, PIDs, command lines, and folders stay on this Mac. There is no account, no analytics, and no paid tier. The only optional network call is a Sparkle version check you can turn off.

<p align="center">
  <img src="docs/assets/panel.png" width="420" alt="Portkeep panel — leftovers, projects, and who started them">
</p>

## What it looks like

<p align="center">
  <img src="docs/assets/hero.png" alt="Portkeep on the Mac menu bar">
</p>

<table>
  <tr>
    <td width="50%">
      <img src="docs/assets/panel.png" alt="The menu bar panel">
      <p align="center"><sub>The panel. Leftovers first. Then your projects.</sub></p>
    </td>
    <td width="50%">
      <img src="docs/assets/cli.png" alt="portkeep CLI">
      <p align="center"><sub>Same picture from the terminal.</sub></p>
    </td>
  </tr>
</table>

- **Who started this** — Cursor Agent, Claude Code, your terminal, or an orphan reparented to launchd.
- **Stop the tree** — not just the pid on the port. The wrapper, the children, then SIGKILL if it hangs.
- **Stable ports** — `portkeep alloc web` gives the same port back in this worktree.
- **Policy** — postgres, redis, ollama, and other known services stay locked. `--force` is SIGKILL only; it does not bypass policy.

## Install

Menu bar extra — no Dock icon. Hotkey: Control-Option-P.

```sh
git clone https://github.com/Slowper/Portkeep.git
cd Portkeep
xcodegen generate
xcodebuild -project Portkeep.xcodeproj -scheme Portkeep -configuration Debug \
  -derivedDataPath /tmp/portkeep-dd build
open /tmp/portkeep-dd/Build/Products/Debug/Portkeep.app
```

Needs macOS 14+, Xcode 16+, and [XcodeGen](https://github.com/yonaskolb/XcodeGen). Open Settings from the panel, or run `portkeep settings`.

A signed, notarized disk image is not in this repo. Build one with `./scripts/release.sh` if you have a Developer ID.

## CLI

After Settings → Agents → Install, or from `Portkeep.app/Contents/Helpers/portkeep`:

```
portkeep list                 what's listening
portkeep who 3000             who owns a port
portkeep alloc web            same port next time, in this worktree
portkeep stop 3000            stop the process tree
portkeep install --mcp        CLI + Cursor / Claude Code MCP
portkeep snippet --write      AGENTS.md block for this folder
```

<p align="center">
  <img src="docs/assets/cli.png" width="720" alt="portkeep list, who, and stop">
</p>

## Privacy

Nothing leaves this Mac except an optional Sparkle version check. See [website/privacy.html](website/privacy.html).

## MDM

`mdm/` has a sample profile. `scripts/pkg.sh` builds an installer pkg. Preference domain: `com.sajidpalagiri.portkeep`. See `mdm/IT.txt`.

## License

[MIT](LICENSE). Issues and pull requests are welcome. Keep stops policy-safe. Do not commit signing keys, notarized disk images, or `~/.portkeep` data.
