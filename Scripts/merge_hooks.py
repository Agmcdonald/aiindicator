#!/usr/bin/python3
"""Safely merge the Codex hooks file."""
from hook_config import CODEX_EVENTS, merge_cli

if __name__ == "__main__":
    raise SystemExit(merge_cli(CODEX_EVENTS, "codex_hook.py"))
