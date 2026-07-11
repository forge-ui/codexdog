# CodexRelay

Native macOS menu bar watchdog for the ChatGPT Codex client. It reads the current account allowance through the Codex app-server bundled with ChatGPT, rotates through any number of isolated account profiles when either official quota window reaches the configured threshold, restarts ChatGPT, and submits deduplicated recovery turns for recent unfinished tasks.

`CodexRelay.app` owns the watchdog worker. Quitting the menu bar app stops the worker immediately; there is no independent KeepAlive LaunchAgent.

The app is menu-bar-only and uses native SwiftUI Liquid Glass on macOS 26, with a Material fallback on older supported systems. Every account shows the official 5-hour (`300` minutes) and 7-day (`10080` minutes) quota windows, reset time, and last synchronization time. Automatic switching, enrollment, account actions, and destructive confirmation all stay inside the menu-bar panel rather than opening detached modal windows.

The optional local-usage section reports today and 30-day token/cost estimates for all histories under the current `~/.codex`. Costs are API-equivalent estimates, not ChatGPT subscription charges. Codex session logs do not contain an account identifier, so histories created in a shared `CODEX_HOME` cannot be split reliably by account. An installed CodexBar CLI is used only as the read-only scanner for this section; watchdog, quota synchronization, switching, and recovery remain independent of CodexBar.

## Requirements

- macOS 14 or newer; initially verified on macOS 26.
- `/Applications/ChatGPT.app` with its bundled `codex` binary.
- Two or more ChatGPT accounts owned and used by the same person.
- Optional: CodexBar installed when local token/cost history is desired.

Automated subscription rotation may conflict with provider usage restrictions. Review the applicable OpenAI terms before disabling dry-run.

## Build

```bash
./script/build_and_run.sh --verify
```

This builds both SwiftPM executables, stages `dist/CodexRelay.app`, launches it, and verifies the menu bar process. Use `./script/build_and_run.sh --test` for tests.

## Enroll accounts

```bash
swift run codex-relay init
swift run codex-relay profile login account-a
swift run codex-relay profile login account-b
swift run codex-relay profile login account-c
swift run codex-relay profile verify account-a
swift run codex-relay profile verify account-b
swift run codex-relay profile list
```

There is no account-count limit. Every successful `profile login` appends the account to the rotation order. Use the person-plus button in the menu bar panel to add another account. The menu reads the verified email claim from each Codex OAuth credential and uses it as the visible account name; internal profile identifiers remain filesystem-safe and are not shown.

Duplicate profiles that resolve to the same ChatGPT `account_id` are detected and skipped during rotation. Re-login one of the profiles with a different account when the menu displays a duplicate warning.

Each account has an actions menu in the upper-right corner:

- **Pause scheduling** keeps the OAuth credential and last quota snapshot, but excludes the account from automatic rotation and standby quota polling. Resume it from the same menu.
- **Delete account** removes the credential, cached quota, and rotation entry stored by CodexRelay. It does not delete the OpenAI account or immediately sign the ChatGPT client out of a currently active account.

Each login uses an isolated `CODEX_HOME` and device OAuth. Open the displayed URL and authenticate the requested account. Do not sign out of the ChatGPT desktop app while enrolling profiles: signing out can invalidate the token that was just saved.

`profile save` remains available for importing the account currently present in `~/.codex/auth.json`, but isolated login is the recommended path:

```bash
swift run codex-relay profile save account-a
```

Edit `~/Library/Application Support/CodexRelay/config.json` when advanced tuning is needed. The default threshold is 99% used (1% remaining). A newly exhausted account is evaluated immediately; a previous switch timestamp does not delay failover to the next healthy account.

## Install the menu bar app

```bash
./script/build_and_run.sh --install
```

This installs the app at `~/Applications/CodexRelay.app`, removes any legacy `com.local.codex-relay` LaunchAgent, and launches the menu bar component. Quitting the component also stops its child watchdog process. Relaunch the app to resume monitoring.

Run `swift run codex-relay diagnose` at any time for a read-only app-server, quota, and recoverable-task check.

At a threshold event, the engine checks scheduled profiles in rotation order before closing ChatGPT. Paused, missing, duplicate, or already exhausted profiles are skipped. If none is usable, ChatGPT is left on the current account and the error is shown in the menu bar app.

OAuth access and refresh tokens can rotate while an account is active. CodexRelay synchronizes the current `~/.codex/auth.json` back into that account's isolated profile after quota reads, immediately before a switch, and after validating the target account. Credential synchronization and activation writes verify `tokens.account_id`, so a refreshed credential cannot overwrite a different stored account. An invalid current token is treated as a failover condition; invalid standby accounts are skipped and reported. Profile credentials remain on this Mac under `~/Library/Application Support/CodexRelay` with owner-only file permissions.

The switch itself is a persistent transaction: source credentials are backed up with owner-only permissions, the target identity is activated and verified, target quota is validated, and only then is the switch committed. If activation or terminal validation fails, CodexRelay restores the source credential and reopens ChatGPT. A filesystem advisory lock serializes state-changing critical sections between the watchdog and account/configuration commands; the interactive device-OAuth wait does not hold that global lock. An interrupted transaction is reconciled on the next poll.

## Recovery behavior

CodexRelay preserves `~/.codex` and changes only `auth.json`. It selects active, failed, or recently updated non-archived tasks, resumes them through app-server, and submits a recovery message carrying a stable switch identifier. Before retrying a lost response, it reads the task and searches for that marker; accepted recovery turns are therefore not submitted again merely because a response or local state write was interrupted.

Recovery is capped at 20 tasks by default and submitted in batches of three, so quota monitoring continues while recovery is in progress. The app-server that owns each submitted turn stays alive until it emits `turn/completed` or reaches its safety timeout; only a completed marker is persisted as recovered. Recovery turns use Codex's risk-evaluating automatic approval reviewer instead of waiting for an unattended menu-bar confirmation; this is not an unconditional approval mode. A task that fails three genuine recovery attempts is recorded separately as failed rather than marked complete. If another switch becomes necessary mid-recovery, pending entries retain their original identifiers.

Local development builds are ad-hoc signed automatically. Public distribution requires a Developer ID Application identity, hardened runtime signing, notarization, and stapling. The current SwiftPM build produces an Apple Silicon (`arm64`) app.

Task continuation across accounts is best-effort behavior built on the local task history and current app-server behavior; OpenAI does not document it as a guaranteed cross-account handoff contract. Validate it with two healthy enrolled accounts before relying on unattended switching.
