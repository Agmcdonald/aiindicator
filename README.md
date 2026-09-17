# BlinkStatus

Two independent blink(1) mk2 indicators for the signed-in macOS user:

| Device serial | Applications | LED 1 while open | LED 2 |
| --- | --- | --- | --- |
| `2000A159` | ChatGPT / Codex | White | Green: ready; yellow: working; red: needs input |
| `2000A15D` | Claude Desktop / Claude Code | Orange (`FF8000`) | Green: ready; yellow: working; red: needs input |

Attention outranks working, which outranks ready within each group. The devices are independent. Both LEDs turn off when that group's apps and leased command-line sessions are closed. Hook sessions expire after stale leases; abrupt terminal termination may leave the presence light on until its lease expires (up to 24 hours for ready/attention; two hours for working).

## Install

Requires macOS 13+, a Swift 6.4 toolchain, `/usr/bin/python3`, and the previously installed `/opt/homebrew/bin/blink1-tool`. Connect both approved devices before installing. From the source checkout, run:

```bash
/bin/bash Scripts/install.sh
```

Run as your normal account, without `sudo`. Installation builds the release helper in a temporary directory, checks both device serials, and installs to `~/Library/Application Support/BlinkStatus/`. It creates and starts the `com.andrewmcdonald.blink-status` user LaunchAgent. The helper starts again on login and restarts after an unsuccessful exit.

The installer merges handlers into `~/.codex/hooks.json` and `~/.claude/settings.json`. Existing settings and unrelated hooks are preserved. Repeating a merge adds no duplicates. Every changed existing configuration gets a private timestamped backup next to the original, and its path is printed. Invalid JSON, duplicate object keys, malformed hook structures, and symbolic-link paths are refused. Symlink-based dotfile configurations must be handled explicitly before using this installer.

Each adapter uses a two-second hook limit and exits successfully even when the daemon is unavailable. Hooks do not issue approval decisions. Codex events: UserPromptSubmit, PermissionRequest, PostToolUse, Stop, Interrupt, SessionEnd. Claude events: SessionStart, UserPromptSubmit, PostToolUse, PermissionRequest, Notification, Stop, SessionEnd. Restart existing CLI sessions after installing so they reload hook configuration.

Grant `blink-statusd` access in System Settings → Privacy & Security → Accessibility when prompted. The installer invokes the installed helper's permission request. Code hooks work without Accessibility; desktop conversation status detection needs it. Desktop status depends on accessible UI labels and visible conversation state, so app UI changes can reduce its accuracy. No transcript text is stored in logs; lifecycle events stay on a local private socket.

Installation writes files individually with atomic replacement. It is not one transaction across both apps, files, and launchd. If an operation fails, retain printed backup paths, correct the reported problem, and rerun. The helper may be stopped during a failed update. A failed uninstall preserves remaining files so it can be rerun. Logs are at `~/Library/Logs/BlinkStatus/`.

## Uninstall

The uninstaller is copied with its supporting utilities and works even after this source checkout is moved or deleted:

```bash
/bin/bash "$HOME/Library/Application Support/BlinkStatus/uninstall.sh"
```

From the checkout, `/bin/bash Scripts/uninstall.sh` also works. It stops only this integration's user LaunchAgent, removes only BlinkStatus hook handlers, and deletes only the recognized BlinkStatus support directory and matching plist. Backups remain beside the app configurations, and diagnostic logs remain in the log directory. Homebrew, blink1-tool, unrelated hooks, and unrelated settings remain installed. Removed helper files can be recreated by running the installer; configuration changes can be recovered from the printed backups. Uninstall refuses an unrecognized support directory or plist instead of deleting it.

## Development verification

```bash
swift test --scratch-path /private/tmp/blink-status-build
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests/Python -v
bash -n Scripts/install.sh Scripts/uninstall.sh
plutil -lint Resources/com.andrewmcdonald.blink-status.plist
```

Packaging tests operate only in temporary directories. They never run the real installer, control devices, modify actual application settings, or start/stop launchd.
