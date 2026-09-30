# MacClaude

<img src="docs/images/macclaude-icon.png" width="128" alt="MacClaude icon">

[![Build and test](https://github.com/anderskraken/macclaude/actions/workflows/build.yml/badge.svg?branch=main)](https://github.com/anderskraken/macclaude/actions/workflows/build.yml)
[![Preview v0.2.5](https://img.shields.io/badge/preview-v0.2.5-blue)](https://github.com/anderskraken/macclaude/releases/tag/v0.2.5)
[![macOS 14+ · Apple Silicon](https://img.shields.io/badge/macOS-14%2B%20%C2%B7%20Apple%20Silicon-black)](#download)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

A tiny native Mac menu bar app for switching Claude Desktop accounts while keeping the same local Claude Code sessions, skills and memory. Swift and AppKit. No package dependencies or background polling.

## Download

**[Download MacClaude for Apple Silicon](https://github.com/anderskraken/macclaude/releases/download/v0.2.5/MacClaude.zip)** · [Release notes](https://github.com/anderskraken/macclaude/releases/tag/v0.2.5) · [SHA-256 checksum](https://github.com/anderskraken/macclaude/releases/download/v0.2.5/SHA256SUMS.txt)

Requires **macOS 14+**. Account-to-account transfers support **Claude Desktop 2.9939.4**; reopening the account already holding your sessions also works with **2.16120.0**. Transfers on newer versions remain paused pending compatibility review. This is an unofficial preview. Intel binaries are not included.

Unzip, move **MacClaude.app** to Applications, and open it. **Sessions here** shows where your shared history lives; **Running** shows which account is open. Your existing Claude login is available immediately. To add another account, choose **Add Account**, sign in and open Claude’s **Code** tab, then select that account again in MacClaude.

## Trust and verification

- **Signed by Snega AS** (Apple team `P5VRX5EBV4`), notarized by Apple, with a stapled ticket. [Verify your download](docs/NOTARIZATION.md#verify-a-download).
- **Credentials stay with Claude.** MacClaude does not read login credentials, send telemetry, or make network requests. Claude handles authentication and its own network traffic.
- **Testable locally.** Automated tests use temporary fixtures. Native session sharing was validated on Claude 2.9939.4. [Coverage and remaining limits](docs/TESTING.md).
- **Source available under MIT.** Inspect the [switching implementation](Sources/MacClaudeCore/SharedSessionStore.swift), [build workflow](.github/workflows/build.yml), and [release script](scripts/notarize.sh).

## How it works

Switching gracefully quits Claude, moves the **same session directory and worktree registry** into the selected account’s profile, and opens Claude’s Code tab. There are no routine session copies, imports or synchronization. **One Claude account runs at a time**; finish active work and switch through MacClaude.

Sharing history does not guarantee identical reasoning context after an account or model change. [Continuity limits](docs/USAGE.md#session-history-and-reasoning-continuity).

Accounts and the menu bar show **percent used** and the age of Claude’s recorded usage. Switching shows each step as it happens. **Copy Diagnostics** produces a local report without account names, private paths, credentials or conversations.

Project files and Claude Code’s usual shared configuration stay in place. Logins, cloud chats, Desktop preferences and schedules remain account-specific. An initial metadata backup and recovery journal support interrupted transfers; they do not back up transcripts or repositories. Back up your Claude and MacClaude profile directories before first use. Independently populated histories are refused rather than merged.

[After a reboot or update](docs/USAGE.md#after-a-reboot-or-claude-update) · [Usage and recovery](docs/USAGE.md) · [Architecture](docs/ARCHITECTURE.md) · [Report an issue](https://github.com/anderskraken/macclaude/issues)

## Build

Requires macOS 14+ and Xcode with Swift 6. Select Xcode in **Settings → Locations → Command Line Tools**, then:

```sh
git clone https://github.com/anderskraken/macclaude.git
cd macclaude
make test
make build
open build/MacClaude.app
```

Local builds are ad-hoc signed. [Developer ID signing and notarization](docs/NOTARIZATION.md) require your own Apple credentials.

## Contributing

Bug reports, documentation fixes and pull requests are welcome. Start with [CONTRIBUTING.md](CONTRIBUTING.md) for setup, the source map and compatibility testing. Report vulnerabilities privately using [SECURITY.md](SECURITY.md).

MacClaude is independent software and is not affiliated with Anthropic.
