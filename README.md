# Agent Status Bar

macOS menu bar app for tracking Codex and Claude Code clients running inside cmux.

## MVP

- Counts Codex and Claude Code sessions attached to cmux terminal surfaces.
- Reads cmux session, hook, and workstream files from `~/Library/Application Support/cmux`
  and `~/.cmuxterm`.
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

- cmux session surfaces from `session-com.cmuxterm.app.json`.
- cmux agent hook sessions from `~/.cmuxterm/<agent>-hook-sessions.json`.
- cmux Feed / agent activity from `~/.cmuxterm/workstream.jsonl`.
- Codex sqlite logs for detailed running, approval-waiting, idle, and stale
  states when a live Codex process is attached to a cmux TTY.
- Claude Code credit-left percentages from
  `~/.claude/plugins/claude-hud/.usage-cache.json`.
- Codex credit-left percentages from the local Codex app-server
  `account/rateLimits/read` API.

For full Codex Feed / restore metadata, install cmux's Codex integration:

```bash
cmux hooks setup --agent codex
```
