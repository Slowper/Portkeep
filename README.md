# Portkeep

A macOS menu bar app for leftover localhost ports. It shows who is listening, which project they belong to, and whether a human, Cursor, or Claude Code started them. You can stop the whole process tree, reserve a stable port per worktree, and give agents a CLI plus MCP.

Nothing leaves this Mac except an optional Sparkle version check.

## Requirements

- macOS 14 or later
- Xcode 16+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## Build

```sh
xcodegen generate
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project Portkeep.xcodeproj -scheme Portkeep -configuration Debug \
  -derivedDataPath /tmp/portkeep-dd build
open /tmp/portkeep-dd/Build/Products/Debug/Portkeep.app
```

The app is a menu bar extra (`LSUIElement`), not a Dock app. Open Settings from the panel, or run `portkeep settings`. Hotkey: Control-Option-P.

A signed, notarized disk image is not in this repo. Build one with `./scripts/release.sh` if you have a Developer ID and App Store Connect notary credentials. The Sparkle private key and Apple API key stay on the maintainer’s machine.

## CLI

After `portkeep install`, or from `Portkeep.app/Contents/Helpers/portkeep`:

```
portkeep list                 what's listening
portkeep who 3000             who owns a port
portkeep alloc web            same port next time, in this worktree
portkeep stop 3000            stop the process tree
portkeep install --mcp        CLI + Cursor / Claude Code MCP
portkeep snippet --write      AGENTS.md block for this folder
```

`portkeep stop` will not kill protected names such as postgres, redis, or ollama. `--force` is SIGKILL only; it does not bypass policy.

## License

Source is [MIT](LICENSE). Viewing ports stays free. Portkeep Pro is a one-time $29 unlock for stop, alloc, leftovers, MCP, audit, and org seats. Keys are honor-system (`PKP-…` personal, `PKO-<ORG>-<SEATS>-…` company) and stored in the Keychain, not this repository.

## Privacy

Ports, PIDs, command lines, and folders stay on the Mac. See [website/privacy.html](website/privacy.html).

## MDM

`mdm/` has a sample profile and `scripts/pkg.sh` builds an installer pkg. Preference domain: `com.sajidpalagiri.portkeep`. See `mdm/IT.txt`.

## Contributing

Issues and pull requests are welcome. Keep stops policy-safe: do not add a flag that bypasses protected processes or allowed roots. Do not commit signing keys, notarized disk images, or `~/.portkeep` data.
