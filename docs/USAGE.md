# MacClaude — Account Switcher

A tiny native Mac menu bar app for opening and switching between Claude Desktop accounts. Written in Swift 6 and AppKit. No dependencies, web views, telemetry, network client, or background polling.

**Preview · macOS 14+ · Apple Silicon · Claude Desktop 2.9939.4**

## Try it

Download the ZIP from the [release page](https://github.com/anderskraken/macclaude/releases/tag/v0.2.5), unzip it and move **MacClaude.app** to Applications before opening it or enabling Launch at Login.

1. **Personal** uses your existing Claude profile. You can rename this label.
2. Choose **Add Account…**, enter a name, sign in in the new Claude window, and open its **Code** tab.
3. After the first sign-in, select the new account again to load the shared Code history.
4. Choose an account in the menu bar, or use **Switch** in the Accounts window. Switching quits Claude gracefully, moves the same session folder, and opens the selected login. The running account has a checkmark and green dot. **Sessions here** separately identifies the account holding the shared history, even when it is closed. Use **Open** for that account; **Switch** transfers the shared sessions to another account.

Closing MacClaude's Accounts window leaves its menu bar item available. Quitting MacClaude leaves Claude running. Each account signs in directly with Claude; MacClaude does not read credentials.

The published Apple Silicon app is Developer ID signed by Snega AS and notarized by Apple. Local builds remain ad-hoc signed unless a signing identity is supplied.

## What follows you

Your repositories and documents are ordinary shared files. The accounts also use the normal Claude Code configuration directory, typically `~/.claude`, so local Code skills, instructions, memory, agents, plugins, and transcripts remain available where Claude uses those locations. MacClaude does not set `CLAUDE_CONFIG_DIR` or change your environment. Existing custom configuration or organization policy can affect this behavior.

Local Code session records move as one real directory, retaining the native sidebar entries and their existing transcript references. The worktree registry moves with them so checkout paths and leases follow the sessions. Routine switching does not copy records, import sessions, or synchronize histories. Account schedules remain at their original account paths. Cloud chats, Chat memory, cloud Projects, Cowork sessions, and Desktop preferences/connectors stay with their account/profile.

One Claude account runs at a time. Finish active work before switching. MacClaude will not force-quit a process or move history while a known session writer remains alive. Always switch through MacClaude: starting another profile directly can create a separate history, which this version refuses to merge automatically.

## Compatibility

Shared-store switching supports **Claude Desktop 2.9939.4**. On newer versions, you can reopen the account already holding the shared store after MacClaude verifies its identity. Moving sessions to another account still requires a compatibility check. Pending transcript imports, ambiguous account/org namespaces, independently populated histories, unexpected files and cross-volume moves stop with an explanation. See [architecture](ARCHITECTURE.md) and [validation](TESTING.md).

### Session history and reasoning continuity

MacClaude shares local session history and project state. It cannot guarantee that a model reuses identical reasoning after an account or model change. Account and model changes can affect continuation; their effect on Desktop Code reasoning continuity remains unverified.

MacClaude preserves stored session contents and leaves request construction to Claude. It does not rewrite transcripts, strip thinking blocks or change API settings. Sidebar visibility and a successful continuation are useful checks, but do not prove earlier thinking was retained.

## After a reboot or Claude update

macOS may reopen Claude’s original profile instead of your last MacClaude account. An empty Code sidebar there does not mean the shared history was deleted: it can still be in the other account’s profile. Quit Claude and open the last-used account through MacClaude.

MacClaude can reopen the recorded session owner on a newer Claude version without moving any session files. An interrupted transfer or changed directory identity still stops the operation. Do not create replacement sessions, copy histories together, or restore yesterday’s initial backup over today’s work to fix an empty list. Use the diagnostics below to identify which account holds the store.

## Alerts and recovery actions

After an unchecked Claude update, the Accounts window names the account holding your sessions and offers **Open <account>**. Transfers and Add Account are disabled until compatibility is checked. The menu bar uses the same restrictions.

Error alerts use **Close** to dismiss them, with specific actions when available: **Show Claude**, **Show Profile Folders**, **Show Recovery Folder**, or **Choose Claude App…**. These actions do not retry a session transfer. Startup failures that exit the app say **Quit** or **Show Folder & Quit**.

The status shows the actual stage: checking sessions, closing Claude, preparing sessions, opening the chosen account, and checking its profile. A delayed macOS launch explains that it is taking longer than expected and keeps additional launches blocked through profile verification. Late launch failures remain visible. There is no Cancel button because MacClaude cannot cancel that pending request. Invalid account names are explained inside the naming dialog; Save stays disabled until corrected. **Remove from List / Cancel** only affects the account list, and Cancel is the default.

## Files and recovery

| Location | Purpose |
| --- | --- |
| `~/Library/Application Support/MacClaude/config.json` | Account list and app preference |
| `~/Library/Application Support/MacClaude/Profiles/<id>/` | Additional Claude profile |
| `~/Library/Application Support/Claude/` | Existing Claude profile; kept in place |
| `~/.claude/` | Usual shared Claude Code files; not modified by MacClaude |
| `~/Library/Application Support/MacClaude/SharedSessions/` | Initial backup, active-store identity, and any interrupted-switch journal |

Removing an account removes only its list entry. Its profile folder and login are retained. The original profile and the profile holding the shared session store cannot be removed; switch away first. Back up all Claude profile directories and the MacClaude directory together. The shared store lives inside whichever account was last active, under `claude-code-sessions/<account>/<org>`.

If MacClaude reports an interrupted switch, quit Claude and select the desired account again. Recovery uses recorded directory/file identities and refuses unexpected replacements. Initial backups are retained under `SharedSessions/Backups`, with a namespace manifest for manual restoration. Do not delete a recovery journal or restore an old backup over newer sessions while Claude is running.

If browser sign-in opens the wrong Claude instance, finish your work, quit the other Claude instances, and retry. macOS protocol callbacks are not routed by MacClaude. For Claude updates, finish your work and quit all Claude instances, allow Claude to update, then reopen your accounts from MacClaude. MacClaude does not modify or disable Claude's updater.

## Usage and diagnostics

Accounts and the menu bar show recorded usage as **5h: 20% used · Week: 40% used**, followed by the measurement’s age. Readings older than 15 minutes are marked **stale** and dimmed. These are Claude’s last local measurements, not live quota checks or reset predictions. Missing or ambiguous readings are omitted. Opening the menu or refreshing Accounts reads the local file; there is no background polling.

Choose **Copy Diagnostics** in the menu bar or Accounts’ **More options** menu. It copies app versions, the running account, session holder, transfer compatibility, current switching stage, recovery status and the last failure code. Account numbers match their order in the Accounts window. Names, private paths, credentials and conversation contents are excluded; nothing is uploaded. A report copied during a switch reports the session location as checking.

The same redacted read-only report is available from the command line (the separate process cannot report the running MacClaude instance’s progress or last error):

```sh
/Applications/MacClaude.app/Contents/MacOS/MacClaude --diagnostics
```

## Building and distribution

See the [README](../README.md#build) for local builds and [signing and notarization](NOTARIZATION.md) for release instructions and download verification.
