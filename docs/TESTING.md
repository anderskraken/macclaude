# Testing and compatibility

## Automated tests

Run `make test` on macOS with Swift 6. Tests use temporary fixtures and synthetic data; they do not require Claude, authenticated accounts or access to your real profiles. Run `make build` to check the application bundle and ad-hoc signature.

Coverage includes:

- Account configuration, private atomic writes, schema preservation and stable profile paths.
- Process argument decoding and profile identity, including Unicode, traversal, symlinks and malformed input.
- Local usage percentages, source timestamps, stale readings and ambiguous organizations.
- A→B→A movement of the same session directory and worktree registry, preserving identity, contents and account-local schedules.
- Refusal of independent histories, unsupported layouts and unfinished transcript imports.
- Fault injection at durable transfer boundaries, repeatable recovery and rejection of replaced files or damaged backups.
- Session writer detection, including current and historical transcript ownership.
- Session-location presentation, diagnostic redaction and delayed-launch completion.

CI runs the tests and builds an ad-hoc signed app. It does not authenticate with Claude, exercise account transfers against real profiles or notarize releases.

## Compatibility status

| Claude Desktop | Status |
| --- | --- |
| 2.9939.4 | Cross-account transfers validated and enabled |
| 2.16120.0 | Reopening the recorded session owner validated; transfers disabled |
| Other versions | Transfers disabled pending review |

Native checks on 2.9939.4 verified sidebar visibility, movement of the same directory, worktree-registry preservation, unchanged schedules, conversation recall, rename and archive persistence. These observations do not establish complete coverage of every Claude workflow or identical reasoning after switching accounts or models.

## Reviewing a new Claude version

Use two disposable authenticated profiles and synthetic sessions. Keep your regular Claude profiles out of the experiment. Do not remove the version gate based on static inspection alone.

1. Record the Desktop version, bundled Code version, macOS version and model.
2. Establish same-account restart and resume behavior.
3. Create plain-folder and Git worktree sessions with recognizable synthetic markers. Exercise A→B→A through MacClaude.
4. Verify sidebar visibility, stored messages, recall, tool use, rename/archive persistence and actual worktree continuation.
5. Check session-directory identity, unchanged history before resuming, intact worktree registries, unchanged account schedules and no pending transfer journal.
6. Exercise refusal while writers are running and recovery from interrupted transfers using disposable data.
7. Repeat continuation across an available model change and back. Record native notices and errors separately from successful replies. Record reasoning retention as unknown unless Claude exposes a reliable signal.

Leave request construction and thinking handling to Claude. Do not intercept traffic or rewrite transcripts to make acceptance pass. Include reproducible evidence with any proposed compatibility update.

## Remaining native checks

Clear, rewind, fork, compaction, deletion cleanup and worktree continuation need broader acceptance testing. Fresh login/SSO callbacks, Launch at Login, full update cycles and Intel hardware also need broader validation. Automated storage tests cannot establish these behaviors.

Release validation is documented in [NOTARIZATION.md](NOTARIZATION.md). User-facing recovery instructions are in [USAGE.md](USAGE.md#files-and-recovery).
