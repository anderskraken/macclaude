# MacClaude

<img src="docs/images/macclaude-icon.png" width="128" alt="MacClaude icon">

[![Build and test](https://github.com/anderskraken/macclaude/actions/workflows/build.yml/badge.svg?branch=main)](https://github.com/anderskraken/macclaude/actions/workflows/build.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

A menu bar app for people with more than one Claude account. It switches Claude Desktop between accounts and brings your local Claude Code sessions along, so the Code sidebar doesn't go empty every time you change login.

## Download

[Download MacClaude 0.2.5 for Apple Silicon](https://github.com/anderskraken/macclaude/releases/download/v0.2.5/MacClaude.zip) ([release notes](https://github.com/anderskraken/macclaude/releases/tag/v0.2.5), [SHA-256](https://github.com/anderskraken/macclaude/releases/download/v0.2.5/SHA256SUMS.txt))

You need macOS 14 or later on Apple Silicon. This is an unofficial preview.

Switching and adding accounts only work with Claude Desktop 2.9939.4, the version I tested them on. On any other version MacClaude still opens the account that has your sessions (last tried on 2.16120.0), but it won't move them or add accounts until I've tested that version.

## Getting started

Move MacClaude.app to Applications and open it. Your current Claude login is already there as the first account.

To add another account, choose **Add Account**, sign in in the Claude window that opens, and open the Code tab. Then pick the new account in MacClaude once more to bring your sessions over.

In the menu, **Running** marks the account Claude has open. **Sessions here** marks the account that holds your session history right now.

## How it works

Each extra account gets its own Claude profile folder. When you switch, MacClaude quits Claude, moves the Code session folder and the worktree list into the other account's profile, and opens Claude there. It moves the folder instead of copying it, so there is only ever one history.

Your Code sessions, worktrees and everything in `~/.claude` (skills, memory, CLAUDE.md, plugins) follow you. Each account keeps its own login, cloud chats, projects, Desktop settings and scheduled tasks.

Only one account runs at a time, and you should always switch through MacClaude. If you open another profile yourself, Claude starts a second history there, and MacClaude won't merge the two.

The menu also shows how much of your 5-hour and weekly limits you've used, from Claude's last local reading.

Back up your Claude and MacClaude profile folders before the first switch. MacClaude keeps a copy of the session metadata and a journal to recover an interrupted switch, but it does not back up transcripts or repositories.

After a reboot or a Claude update, macOS may reopen Claude on your original account with an empty Code sidebar. Your sessions are still there. Quit Claude and open the right account from MacClaude.

More detail: [usage and recovery](docs/USAGE.md), [architecture](docs/ARCHITECTURE.md), [testing and known limits](docs/TESTING.md).

## Privacy and signing

MacClaude doesn't read your credentials, send telemetry or make network requests. Claude handles sign-in on its own.

Releases are signed by Snega AS (Apple team `P5VRX5EBV4`) and notarized by Apple. See [how to verify a download](docs/NOTARIZATION.md#verify-a-download). The switching code is in [SharedSessionStore.swift](Sources/MacClaudeCore/SharedSessionStore.swift) if you want to read it before trusting it with your sessions.

## Build

You need Xcode with Swift 6. Select it under **Settings → Locations → Command Line Tools**, then:

```sh
git clone https://github.com/anderskraken/macclaude.git
cd macclaude
make test
make build
open build/MacClaude.app
```

Local builds are ad-hoc signed. To sign and notarize your own builds, see [NOTARIZATION.md](docs/NOTARIZATION.md).

## Contributing

Bug reports and pull requests are welcome. [CONTRIBUTING.md](CONTRIBUTING.md) covers setup, where things live in the source, and how to test against a new Claude version. Report security issues privately, as described in [SECURITY.md](SECURITY.md).

MacClaude is not affiliated with Anthropic.
