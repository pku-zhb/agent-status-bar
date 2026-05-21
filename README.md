# Agent Status Bar

macOS menu bar app for tracking Codex and Claude Code clients running inside Ghostty.

## MVP

- Counts Codex and Claude Code processes that are descendants of Ghostty.
- Reads Claude Code session files from `~/.claude/sessions/<pid>.json`.
- Maps Codex process ids to `~/.codex/logs_2.sqlite` and `~/.codex/state_5.sqlite`.
- Displays Claude and Codex as separate menu bar light arrays.

## UI

The menu bar icon uses two groups: Claude Code first, Codex second. Each light is
one detected session, with stable ordering by session pid.

- White breathing ring: idle but alive.
- Green rotating ring with glow: currently running.
- Red glowing ring: waiting for approval or user attention.
- Gray dim: stale / not updated recently.

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

## Status Sources

This app does not install or read hooks. It derives state from local process and
state files only:

- Ghostty process tree for active Codex / Claude Code clients.
- Codex sqlite logs for running, approval-waiting, idle, and stale states.
- Claude Code session files for busy, idle, and stale states.
