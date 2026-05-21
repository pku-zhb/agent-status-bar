#!/usr/bin/env python3
"""Compatibility no-op for already-running agents with cached old hooks.

AgentStatusBar no longer installs or reads hooks. Some Codex / Claude Code
processes that were already running may still call this path until restarted.
Keep this file as a harmless exit-0 shim so those stale in-memory hooks do not
surface errors to the user.
"""

from __future__ import annotations

import sys


def main() -> int:
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
