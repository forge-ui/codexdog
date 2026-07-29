# CodexDog

[English](README.md) | [简体中文](README.zh-CN.md)

A native macOS menu bar watchdog for switching between your ChatGPT Codex accounts when the active account runs out of quota.

The app is installed as `CodexDog.app`.

![CodexDog menu showing multiple accounts, weekly quota, local usage, and automatic switching](docs/images/codexdog-menu.png)

## Features

- Manage any number of ChatGPT Codex accounts.
- Show the quota windows currently returned by OpenAI.
- Switch accounts automatically at 1% remaining quota.
- Restart ChatGPT and continue recent unfinished tasks after a switch.
- Pause scheduling or remove individual accounts.
- Show local Codex token and API-equivalent cost estimates with a built-in scanner.

## Requirements

- macOS 14 or newer.
- `/Applications/ChatGPT.app` with Codex available.
- Two or more ChatGPT accounts that you own and manage.

## Install

```bash
git clone https://github.com/forge-ui/codexdog.git
cd codexdog
./script/build_and_run.sh --install
```

The app is installed at `~/Applications/CodexDog.app`. It runs only in the menu bar and does not stay in the Dock. Quitting the menu bar app also stops the watchdog.

## Use

1. Open CodexDog from the macOS menu bar.
2. Use the add-account button to import the account already signed in to Codex or log in with another account.
3. Add as many accounts as needed.
4. Enable **Automatic switching**.

CodexDog reads official quota data through the Codex app-server. The displayed rows follow the quota windows OpenAI currently returns instead of assuming fixed 5-hour and 7-day limits.

Local token and cost estimates are calculated directly from local Codex session logs. The embedded
scanner is derived from CodexBar v0.44.0 under the MIT License; see
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

Account credentials stay on this Mac under the legacy-compatible `~/Library/Application Support/CodexRelay` data directory with owner-only permissions. Switching preserves `~/.codex` and replaces only the active `auth.json` credential.

Task continuation is best effort because cross-account recovery is not an official OpenAI contract.

## Development

```bash
swift test
./script/build_and_run.sh --verify
```
