#!/usr/bin/python3
"""Safely merge hooks into Claude Code settings."""
from hook_config import CLAUDE_EVENTS, merge_cli

if __name__ == "__main__":
    raise SystemExit(merge_cli(CLAUDE_EVENTS, "claude_hook.py"))
