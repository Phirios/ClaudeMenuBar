# ClaudeMenuBar

<p align="center">
  <img src="assets/icon.png" width="128" alt="ClaudeMenuBar Icon">
</p>

<p align="center">
  A native macOS menu bar app that displays your Claude Code rate limit usage in real time.
</p>

<p align="center">
  <img src="assets/topbar-example.png" alt="Menu Bar Example">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-blue" alt="macOS">
  <img src="https://img.shields.io/badge/Swift-5.9-orange" alt="Swift">
</p>

## Features

- **Dual limit visualization** — Custom icon with an outer ring (5h session limit, App Store-style circular progress) and an inner circle (7d weekly limit, fills vertically)
- **Color-coded** — Green (<55%), Yellow (55-69%), Orange (70-84%), Red (85%+)
- **Session percentage** — Shown as text next to the icon with a time-remaining progress bar underneath
- **Live indicator** — Pulsing dot in Claude's brand color when a Claude Code session is actively running; auto-increases refresh rate to 1 min
- **Dropdown menu** — Detailed breakdown with colored ASCII bars, reset times, and status
- **Zero config** — Reads your Claude Code OAuth token from keychain automatically

## How It Works

Makes a minimal API request (`max_tokens: 1`, Haiku model) to `api.anthropic.com` and reads the rate limit headers:

```
anthropic-ratelimit-unified-5h-utilization: 0.32
anthropic-ratelimit-unified-7d-utilization: 0.40
anthropic-ratelimit-unified-5h-reset: 1775523600
anthropic-ratelimit-unified-7d-reset: 1775862000
```

Each check costs ~10 tokens (Haiku).

## Install

### Download (recommended)

1. Download the latest `ClaudeMenuBar-v*.zip` from [Releases](https://github.com/Phirios/ClaudeMenuBar/releases)
2. Unzip and move `ClaudeMenuBar.app` to `/Applications`
3. Cache your Claude Code token (one-time):
```bash
security find-generic-password -s "Claude Code-credentials" -w | \
  python3 -c "import sys,json; print(json.loads(sys.stdin.read())['claudeAiOauth']['accessToken'])" \
  > ~/.claude/claude-menubar-token
```
4. Launch the app

> **Note:** macOS may show "unidentified developer" warning on first launch. Right-click the app and select Open, then click Open in the dialog.

### Build from source

```bash
git clone https://github.com/Phirios/ClaudeMenuBar.git
cd ClaudeMenuBar
swift build -c release
```

Then create the app bundle:
```bash
APP="$HOME/Applications/ClaudeMenuBar.app/Contents"
mkdir -p "$APP/MacOS"
cp .build/release/ClaudeMenuBar "$APP/MacOS/"
```

### Launch at login (optional)

```bash
osascript -e 'tell application "System Events" to make login item at end with properties {path:"/Applications/ClaudeMenuBar.app", hidden:false}'
```

## Menu Bar

```
[icon] 32% ●     ← session %, pulsing dot = claude is running
       ▓▓░░░     ← time remaining bar

Click to open:
┌─────────────────────────────────────────────┐
│ ● Claude is running                         │
│─────────────────────────────────────────────│
│ ✅ Allowed                                  │
│─────────────────────────────────────────────│
│ 5h  [██████░░░░░░░░░░░░░░] 32% ◀           │
│       Reset: in 3h 42min                    │
│─────────────────────────────────────────────│
│ 7d  [████████░░░░░░░░░░░░] 40%             │
│       Reset: in 4d 2h                       │
│─────────────────────────────────────────────│
│ Refresh Now                          ⌘R     │
│ Settings...                          ⌘,     │
│─────────────────────────────────────────────│
│ Quit                                 ⌘Q     │
└─────────────────────────────────────────────┘
```

## Requirements

- macOS 14+
- Claude Code CLI (authenticated via `claude auth login`)

## License

MIT
