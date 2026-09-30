# Architecture

MacClaude is a Swift 6/AppKit menu bar app. It uses one unmodified Claude installation and separate Electron profiles for account logins. The shared-store integration is based on inspection and native testing of **Claude Desktop 2.9939.4**, not a supported Anthropic API. Transfers on other versions are blocked. Reopening the recorded owner is permitted after checking its directory identity, the absence of a pending transaction, and the existing storage layout; it never calls transfer or recovery.

## One store, one active account

The original account uses Claude’s default profile. Additional accounts use stable folders passed through `--user-data-dir`. On a switch, MacClaude:

1. Gracefully quits known Claude instances and waits for their descendant processes. It separately checks native engines and Code’s process registry for writers of the shared transcripts.
2. Validates the Claude version, source and destination namespaces, and destination ownership state.
3. Moves the same `claude-code-sessions/<account>/<org>` directory and profile-level `git-worktrees.json` using same-volume renames. Complete session records and worktree leases are preserved.
4. Keeps each account’s `scheduled-tasks.json` in its original namespace by parking and restoring it during transfer.
5. Opens the destination profile at `claude://code/new`, so Claude loads the shared store into its native Code sidebar.

There are no routine imports, record copies, symlinks, or history synchronization. Selecting the already running account focuses its process. An inactive profile does not retain a second copy of the shared history.

## Data boundaries

| Data | Handling |
| --- | --- |
| Native local Code session records | One directory moves between profiles |
| Worktree registry | Moves with sessions; checkout paths stay unchanged |
| Repositories, documents and transcripts | Stay at their existing paths |
| Usual `~/.claude` configuration | Remains available to Claude; MacClaude does not override `CLAUDE_CONFIG_DIR` |
| Login, cloud chats, Desktop preferences and connectors | Stay in each account/profile |
| Scheduled tasks | Stay with their original account |

Claude’s own settings and organization policy still apply. Shared local configuration does not mean cloud Chat memory or Projects are shared.

## Recovery and refusal conditions

An initial private backup preserves session metadata, schedules and worktree registries. A durable journal records transfers, and interrupted transactions are recovered before launch. Recovery checks recorded file identities and refuses unexpected replacements. **The backup does not include transcripts or repository contents.**

The implementation refuses independently populated histories, ambiguous account/org namespaces, pending transcript imports, unsupported versions, unexpected storage layouts and cross-volume moves. It does not choose a winning history or merge conflicts.

Process checks reduce the risk of concurrent writes but cannot prevent a user from independently launching Claude after a check. Finish active work and use MacClaude for switching. See [validation and remaining limits](TESTING.md) and [recovery instructions](USAGE.md#files-and-recovery).

## Source map

- [SharedSessionStore](../Sources/MacClaudeCore/SharedSessionStore.swift): validation, transactional transfer, backups and recovery.
- [SessionWriterGuard](../Sources/MacClaudeCore/SessionWriterGuard.swift): current and historical transcript ownership checks.
- [ClaudeRuntime](../Sources/MacClaude/ClaudeRuntime.swift) and [ProcessSnapshot](../Sources/MacClaude/ProcessSnapshot.swift): launch, shutdown and process identity.
- [Core tests](../Tests/MacClaudeCoreTests): temporary fixtures and interrupted-transfer fault injection.


## Application identity

The bundle identifier remains `io.github.agensdev.macclaude` for compatibility with existing installations and Launch at Login registrations. Repository ownership is independent of this identifier. Profile storage continues to use `~/Library/Application Support/MacClaude`.
