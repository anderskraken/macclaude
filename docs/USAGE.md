# Using MacClaude

## Set up

Download the ZIP from the [release page](https://github.com/anderskraken/macclaude/releases/tag/v0.2.5), unzip it, and move **MacClaude.app** to Applications before you open it or turn on Launch at Login.

1. Your existing Claude login appears as the first account, named **Personal**. You can rename it.
2. Choose **Add Account…** and enter a name. Claude quits and opens a new sign-in window. Sign in and open the Code tab.
3. Choose the new account in MacClaude again. This moves your Code sessions into it.

After that, choose an account in the menu bar or click **Switch** in the Accounts window. A checkmark in the menu and a green dot in the window mark the account Claude has open. **Sessions here** marks the account that holds your session history, even while Claude is closed. That account shows **Open**, and the others show **Switch**.

Closing the Accounts window leaves the menu bar item running. Quitting MacClaude leaves Claude running. If you quit during a switch, MacClaude finishes the switch first and then quits.

## What follows you between accounts

Your repositories and documents are ordinary files and stay where they are. Every account uses the same Claude Code configuration folder, usually `~/.claude`, so skills, instructions, memory, agents and plugins are shared. MacClaude does not set `CLAUDE_CONFIG_DIR` or change your environment.

A switch moves the Code session folder and the worktree list to the new account. Nothing is copied or merged. Each account keeps its own scheduled tasks, cloud chats, Chat memory, Projects, Cowork sessions and Desktop settings.

Only one account runs at a time. Finish running work before you switch. MacClaude never force-quits Claude, and it won't move sessions while a Code session is still writing. Always switch through MacClaude. If you open another profile yourself, Claude starts a separate history there, and MacClaude won't merge the two.

## Claude versions

Switching and adding accounts work only with Claude Desktop 2.9939.4. On other versions, MacClaude still opens the account that holds your sessions, because that moves nothing. The Accounts window shows an **Open** button for it.

MacClaude also refuses to switch when it finds a pending session import, more than one account or organization folder in a profile, two accounts with their own history, an unexpected file, or folders on different disks. The alert says which one it found. See [architecture](ARCHITECTURE.md) and [testing](TESTING.md) for details.

### Reasoning after a switch

MacClaude moves stored sessions as they are and leaves the requests to Claude. It doesn't rewrite transcripts, strip thinking blocks or change API settings. A continued session can still behave differently after an account or model change, and nobody has measured how much. A session showing up in the sidebar doesn't prove its earlier reasoning carried over.

## After a reboot or Claude update

macOS may reopen Claude on your original account. The Code sidebar there can look empty because your sessions are in another account's profile. Quit Claude and open the right account from MacClaude.

Don't create new sessions to replace the missing ones, copy histories together, or restore an old backup over today's work. Copy Diagnostics tells you which account holds the sessions.

## Alerts

When something goes wrong, the alert explains it and may offer one action: **Show Claude**, **Show Profile Folders**, **Show Recovery Folder** or **Choose Claude App…**. None of these retries the switch.

While a switch runs, the window shows the current step, from checking sessions to opening the chosen account. If macOS is slow to open Claude, the window says so and keeps other launches blocked until Claude is up. There is no Cancel button, because macOS can't cancel a launch it has started.

Removing an account asks for confirmation, and **Cancel** is the default.

## Files and recovery

| Location | Purpose |
| --- | --- |
| `~/Library/Application Support/MacClaude/config.json` | Account list and preferences |
| `~/Library/Application Support/MacClaude/Profiles/<id>/` | Claude profile for each added account |
| `~/Library/Application Support/Claude/` | Your original Claude profile, left in place |
| `~/.claude/` | Shared Claude Code files, not touched by MacClaude |
| `~/Library/Application Support/MacClaude/SharedSessions/` | First-switch backup, the current session owner, and any interrupted-switch journal |

Removing an account only removes it from the list. Its profile folder and login stay on disk. You can't remove the original account or the one that holds your sessions; switch away first. The sessions live inside whichever account was last active, under `claude-code-sessions/<account>/<org>`.

Back up the Claude profile folders and the MacClaude folder together. The first-switch backup in `SharedSessions/Backups` holds session metadata, schedules and worktree lists, with a manifest for restoring by hand. It does not include transcripts or repositories.

If a switch is interrupted, quit Claude and choose an account again. MacClaude finishes the switch first. If the folders changed in a way it can't verify, it stops. If nothing had moved yet, it discards the unfinished switch and tells you what it found. Don't delete the recovery journal or restore an old backup while Claude is running.

If browser sign-in opens the wrong Claude window, finish your work, quit the other Claude windows and try again. MacClaude doesn't route sign-in callbacks. To update Claude, quit every Claude window, let Claude update, then reopen your account from MacClaude. MacClaude doesn't touch Claude's updater.

## Usage and diagnostics

Each account shows usage as **5h: 20% used · Week: 40% used**, with how long ago Claude recorded it. Readings older than 15 minutes are dimmed and marked **stale**. These are Claude's last local readings, not live quota checks. MacClaude reads the file when you open the menu or the window, not in the background.

**Copy Diagnostics** is in the Accounts window's **More options** menu. It copies app and Claude versions, which account is running, which holds the sessions, whether switching is available, the current step, recovery status and the last error code. Accounts appear as numbers in window order. The report has no names, paths, credentials or conversations, and nothing is uploaded.

You can get the same report from the command line. It can't see the running app's progress or last error:

```sh
/Applications/MacClaude.app/Contents/MacOS/MacClaude --diagnostics
```

## Building

See the [README](../README.md#build) to build locally and [NOTARIZATION.md](NOTARIZATION.md) for signing and release.
