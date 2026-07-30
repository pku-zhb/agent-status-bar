# Agent Status Bar

macOS menu bar app for tracking Codex and Claude Code clients running in local terminal sessions.

## MVP

- Counts live Codex and Claude Code processes attached to real TTYs, including
  Terminal, iTerm, tmux, and cmux panes.
- Maps live Codex process ids to `~/.codex/logs_2.sqlite` and
  `~/.codex/state_5.sqlite` for detailed running / approval state.
- Displays Claude and Codex as separate menu bar light arrays.

## UI

The menu bar icon uses two groups: Claude Code first, Codex second. Each light is
one detected session, with stable ordering by session pid.

- White breathing ring: idle but alive.
- Green rotating ring with glow: currently running.
- Red glowing ring: waiting for approval or user attention.
- Gray dim: stale / not updated recently.

The app sends macOS notifications on the same state transitions shown by the
menu bar lights. A live session changing from green to white / gray sends a
title-only "completed this turn" notification, and a session changing from
non-red to red sends a title-only attention notification. Multiple sessions
notify separately instead of being combined into one summary. The initial scan at
launch is ignored so existing states do not trigger stale alerts.

Codex turn state prefers the `needs_follow_up=true/false` lifecycle signal from
local Codex logs. Tool-call and tool-result activity remains active while
pending. If those lifecycle signals are missing, recent turn activity is treated
as active for 90 seconds so older log formats do not immediately flip the light
back to idle during quiet model/tool gaps. Notifications use the same final
client state as the menu bar lights; completion log events do not bypass the
running / idle state machine.

The drop-down menu keeps the same model in Chinese sections: needs attention,
running, idle, and stale / unknown. Technical details such as pid and full cwd are
kept out of the main view; use "复制 JSON 快照" when debugging is needed.

## Run

```bash
swift run AgentStatusBar
```

For a terminal snapshot:

```bash
swift run AgentStatusBar --once
```

Build a local `.app` bundle:

```bash
bash scripts/build_app.sh
open dist/AgentStatusBar.app
```

Install the built app into `/Applications` and register it to start at login:

```bash
bash scripts/install_local.sh
```

## Status Sources

This app does not install or read hooks. It derives state from local process and
state files only:

- Live terminal processes from `ps`.
- Codex sqlite logs for detailed running, approval-waiting, idle, and stale
  states when a live Codex process is attached to a TTY.
- Claude Code session files in `~/.claude/sessions/<pid>.json` for cwd,
  title, and busy / idle / waiting state. If the session file is missing or
  stale, the app falls back to process-child activity.
- Claude Code usage windows from Claude Code's own
  `~/.claude.json` `cachedUsageUtilization` cache. The app never reads Claude
  credentials or calls the Anthropic usage API itself.
- Codex usage from the local Codex app-server `account/rateLimits/read` API.
  Windows are classified by `windowDurationMins`, so weekly-only responses are
  not mislabeled as five-hour usage.
