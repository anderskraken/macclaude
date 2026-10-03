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
| 2.19675.0 | Cross-account transfers and dirty-worktree continuation validated and enabled; original-account replies billing-blocked |
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

Clear, rewind, fork, compaction, deletion cleanup need broader acceptance testing. Dirty-worktree continuation was checked on 2.19675.0 below. Fresh login/SSO callbacks, Launch at Login, full update cycles and Intel hardware also need broader validation. Automated storage tests cannot establish these behaviors.

Release validation is documented in [NOTARIZATION.md](NOTARIZATION.md). User-facing recovery instructions are in [USAGE.md](USAGE.md#files-and-recovery).

## Existing-account acceptance — Claude 2.19675.0

On 2026-10-03, the user requested testing the two existing authenticated accounts. A disposable build with only the checked-version constant changed exercised the normal shutdown, writer checks, transactional transfer and launch path. Both namespaces, schedules, registries and ownership metadata were privately backed up before each round trip. Transfers are now enabled for this exact version alongside 2.9939.4; other versions remain gated.

The secondary account continued a synthetic plain-folder conversation with Opus 5.5 and correctly recalled its earlier marker. Its temporary folder had disappeared after reboot; native folder recovery created the fork used here. Secondary → original preserved the directory and file inodes, every session payload, both account schedules and exchanged registries byte-for-byte at the first inspection. The original account displayed the messages, and a rename persisted after return. The secondary account then correctly recalled the marker again. The original account's billing notice replaced its composer with “Payment past due,” preventing a new response under that login.

Native startup later archived three unrelated sessions and cleaned up their worktree associations. Initial validation conservatively restored only those records, the archive index and the affected registry entries while investigating. Bundled `AutoArchiveEngine` code and exact session lifecycle log entries established the cause: two sessions exceeded the configured 30-day inactivity limit, and one had a merged PR. One missing checkout was removed from the registry; another clean checkout was released to the pool. The original account enabled both rules while the secondary account used disabled defaults. At the user's request, both accounts now use PR-close archiving and a 30-day inactivity limit. A subsequent round trip reproduced the same expected native cleanup, which was retained.

A second synthetic test used a native Git worktree with an uncommitted proof file. Same-account restart preserved its messages and checkout. After secondary → original → secondary, the original account displayed the full tool conversation, and the secondary account read the existing file and appended a test line in the same working directory. Verification retained the history-directory and worktree-directory inodes, every baseline record, the test worktree's lease and checkout, and both account schedules. Registry changes were limited to the confirmed archive cleanup and native trust timestamps; session changes were limited to the test continuation and the three confirmed archive records plus archive index. No pending transfer journal remained. The user's project selection and unsent draft were restored, with sessions in the secondary account.

This establishes history transport, rename persistence, secondary-account model and tool continuation, and continuation in a dirty worktree. Original-account responses remain billing-blocked. Thinking retention and continuation across a model change remain unknown. Native archive policy is account-local; expected archiving, clean-worktree pooling, missing-checkout cleanup and refreshed trust timestamps must be distinguished from transfer corruption. MacClaude preserves native records and delegates this lifecycle behavior to Claude.

Inspection identity: installed `app.asar` SHA-256 `817767bfbad77ea60678e22df90baba2cbabba9dda90201c65a49f0176fc7306`. Relevant chunks include `index.chunk-Bj3j7QA0.js` (archive policy), `index.chunk-1SwQNV5u.js` (worktree pooling), `index.chunk-Dx6WGw95.js` (worktree registry), and `index.chunk-DPWtnchX.js` (session persistence). The automated suite passes **91 tests** after the persistent volume-identity fix and exact-version gate coverage (81 core and ten application tests).
