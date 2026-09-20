# BlinkStatus Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close real reliability gaps between the BlinkStatus implementation and the README contract while preserving independent device operation.

**Architecture:** Keep hardware discovery/rendering inside `BlinkController`, lifecycle serialization inside `DaemonRuntime`/`ProfileChannel`, and one-frame transport inside `UnixSocketServer`. Reject invalid leases at the protocol boundary and order valid lifecycle events per namespaced source before mutating status.

**Tech Stack:** Swift 6.4, XCTest, Python 3 `unittest`, POSIX Unix sockets, shell, launchd plist.

**Spec:** `README.md`

## Global Constraints

- macOS 13+ and Swift tools version 6.4.
- Only serials `2000A159` and `2000A15D` may be controlled.
- Working leases last at most two hours; ready/attention leases last at most 24 hours.
- Hook failure must not block the host CLI.
- Packaging tests use temporary directories and never invoke real launchd, settings, or devices.
- Do not run `Scripts/install.sh`, push, or open a pull request.

## Review Focus

- An older frame arriving late must not overwrite or resurrect a newer state for the same source.
- An update without an expiry and a clear with an expiry must be rejected.
- A second daemon must not unlink and replace a live daemon's socket.
- Replacing a desktop process without an observed closed interval must not retain the old process's accessibility state.
- Missing/reconnected devices and command failures must remain retryable without sending commands to the wrong serial.

---

### Task 1: Lease correctness

**Files:**
- Modify: `Tests/BlinkStatusCoreTests/SocketProtocolTests.swift`
- Modify: `Tests/BlinkStatusCoreTests/ApplicationIntegrationTests.swift`
- Modify: `Sources/BlinkStatusCore/SocketProtocol.swift`
- Modify: `Sources/blink-statusd/Daemon.swift`

**Interfaces:**
- Consumes: newline-delimited `DaemonEvent` values from hooks.
- Produces: strict update/clear lease validation and per-source timestamp ordering.

- [x] Add protocol tests proving update+nil expiry and clear+non-nil expiry are rejected.
- [x] Run the focused protocol tests and observe failures caused by missing validation.
- [x] Add integration tests proving a stale update cannot overwrite a newer update and a stale update cannot resurrect after a newer clear.
- [x] Run the focused integration tests and observe failures caused by arrival-order mutation.
- [x] Add explicit socket protocol errors and per-namespaced-source last-timestamp tracking in `ProfileChannel`.
- [x] Reject state leases beyond two hours for working or 24 hours for ready/attention (`c8e23fb`).
- [x] Reject events more than five minutes in the future and age ordering tombstones after 24 hours (`53e9bc4`).
- [x] Run focused tests, then the full Swift suite.
- [x] Commit the core ordering work as `5995571 fix: enforce ordered expiring hook leases`.

### Task 2: Socket ownership and restart safety

**Files:**
- Modify: `Tests/BlinkStatusCoreTests/UnixSocketServerTests.swift`
- Modify: `Sources/blink-statusd/UnixSocketServer.swift`

**Interfaces:**
- Consumes: a filesystem path for a Unix-domain listener.
- Produces: startup that removes only a demonstrably stale socket and refuses a live endpoint.

- [x] Add a test that starts one server, attempts a second server at the same path, and proves the first remains reachable.
- [x] Run the focused test and observe the second server incorrectly replacing the path.
- [x] Probe an existing socket with a temporary client before unlinking; throw `alreadyRunning` when connect succeeds and remove only refused stale socket nodes.
- [x] Bind first, then probe/reclaim only after `EADDRINUSE`, so simultaneous starters cannot unlink the winner (`5261b33`).
- [x] Prove stale listener paths are reclaimed and live listeners remain reachable.
- [x] Run focused tests, then the full Swift suite.
- [x] Commit the live-listener protection as `2d956ab fix: preserve live daemon socket ownership`.

### Task 3: Desktop replacement and Accessibility denial

**Files:**
- Modify: `Tests/BlinkStatusCoreTests/NativeMonitorTests.swift`
- Modify: `Sources/blink-statusd/main.swift`

**Interfaces:**
- Consumes: ordered `ApplicationPresenceChange` values per desktop bundle identifier.
- Produces: the prior accessibility source is cleared before a replacement PID begins sampling.

- [x] Add a runtime test that records working state from one PID, replaces it directly with another PID whose first sample is unavailable, and expects ready degraded state.
- [x] Run the focused test and observe stale working state.
- [x] Clear the desktop accessibility source when replacing an existing monitor, without closing desktop presence.
- [x] Run focused tests, then the full Swift suite.
- [x] Commit as `693349e fix: clear state when desktop process changes`.

### Task 4: Python and packaging audit

**Files:**
- Modify: `Scripts/blink_install.py`
- Modify: `Tests/Python/test_packaging.py`

**Interfaces:**
- Consumes: Codex/Claude hook JSON and an installation prefix represented only by test temp directories.
- Produces: bounded best-effort hook delivery and idempotent, accurately reported installation/removal.

- [x] Audit all Python adapters, configuration merging, install/uninstall helpers, shell wrappers, and the LaunchAgent against README claims.
- [x] Translate malformed XML plist parser failures into the documented refusal path without masking unrelated failures (`16243f5`, narrowed by `f23e2b2`).
- [x] Keep the installation marker until all other support files are removed so an interrupted uninstall is recognizable on rerun (`655ea3d`).
- [x] Restore the marker atomically if the final support-directory removal fails, then prove a rerun succeeds (`f8e257d`).
- [x] Preserve pre-attempt backups on concurrent-editor aborts and document that deliberate safety behavior.
- [x] Run focused red/green cycles, the complete Python suite, shell syntax checks, and plist lint.

### Task 5: Review and release gate

**Files:**
- Modify if behavior wording changed: `README.md`

**Interfaces:**
- Consumes: all Swift and packaging commits.
- Produces: reviewed branch with documented residual ship risks.

- [x] Review every worker diff against file ownership and README claims.
- [x] Update README only for externally visible behavior.
- [x] Run `swift test --scratch-path /private/tmp/blink-status-build` (66 tests).
- [x] Run `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests/Python` (40 tests).
- [x] Run `bash -n Scripts/install.sh Scripts/uninstall.sh`.
- [x] Run `plutil -lint Resources/com.andrewmcdonald.blink-status.plist`.
- [x] Review the final diff and commit history; report concrete changes and remaining ship work.
