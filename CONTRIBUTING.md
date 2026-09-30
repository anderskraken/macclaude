# Contributing to MacClaude

MacClaude is an unofficial Swift/AppKit companion for Claude Desktop. Small, focused bug fixes, documentation improvements and reproducible compatibility reports are welcome. For a larger change, open an issue first so we can agree on its scope.

## Local setup

Use macOS 14+ and Xcode with Swift 6. Select Xcode in **Settings → Locations → Command Line Tools**. There are no external package dependencies.

```sh
git clone https://github.com/anderskraken/macclaude.git
cd macclaude
make test
make build
open build/MacClaude.app
```

`make run` builds and opens the app. `make dist` packages an ad-hoc signed ZIP. Distribution signing is optional and requires your own credentials; see [NOTARIZATION.md](docs/NOTARIZATION.md).

Tests use temporary fixtures. Launching the app uses your real local MacClaude configuration, and switching accounts moves Claude session metadata. Use a separate macOS user or disposable profiles and synthetic sessions for manual testing.

## Finding the code

- `Sources/MacClaude/`: AppKit UI, Claude launch/shutdown, diagnostics and presentation.
- `Sources/MacClaudeCore/`: profile configuration, usage parsing, session transfers and recovery.
- `Tests/`: isolated storage, process parsing and presentation tests.
- `scripts/`: bundle building, icon generation and notarization.

Read [ARCHITECTURE.md](docs/ARCHITECTURE.md) before changing storage or process handling, and [TESTING.md](docs/TESTING.md) before changing Claude compatibility.

## Pull requests

Explain the problem, the resulting behavior and how you verified it. Run `make test` and `make build` for code changes; include focused regression coverage for changes to storage, recovery or process identity. For documentation-only changes, check links and examples.

Preserve separate credentials and schedules, one active session store, graceful shutdown, version checks and refusal of ambiguous or independently populated histories. Do not bypass safeguards to enable a newer Claude version. Keep changes to supported versions backed by disposable native acceptance tests.

Avoid dependencies, network requests and background polling unless a discussed feature needs them. Never include real profiles, credentials, transcripts, account identifiers or private project paths in fixtures, screenshots or logs. Use **Copy Diagnostics** for bug reports and review attachments before posting.

## Reporting issues

Include MacClaude, Claude Desktop and macOS versions, steps to reproduce, expected and observed behavior, and a redacted diagnostic report if available. For security vulnerabilities, follow [SECURITY.md](SECURITY.md).

Contributions are licensed under the repository's [MIT license](LICENSE). Be respectful and keep discussion focused on the project.
