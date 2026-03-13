# Harden Pipeline — ClawRig Pre-Release (2026-03-12)

## Summary

Full 9-stage hardening pipeline run on ClawRig codebase before release. Covered
audit, adversarial probing, decomposition, execution, triple review, re-probe,
guardrail encoding, and this archive.

## Classification

**Tier 3** — production appliance firmware with OTA updates, no rollback UX,
deployed to customer hardware. High blast radius.

## What was done

### Stage 1-3: Classify, Audit, Probe

- Classified as T3 (production appliance, high blast radius)
- Legibility audit scored the codebase on 7 metrics
- Edge-case analysis found 16 HIGH issues, 10 MEDIUM, 6 LOW, 3 infrastructure gaps

### Stage 4: Decompose

Broke 25+ findings into atomic execution tasks grouped by file ownership:
- Phase 1: Foundational fixes (atomic writes, rate limiter, boot reconciliation)
- Phase 2: Security (file permissions, session handling, check_origin)
- Phase 3: Resilience (watchdog fixes, rollback handling, streaming checksum)
- Phase 4: Infrastructure (boot guard, jq, E2E preflight)
- Phase 5: Review & harden

### Stage 5: Execute (4 commits)

1. `5a88f4a557` — Initial hardening (12 files changed)
   - Atomic file writes (write-tmp-rename) in wizard state
   - ETS rate limiter with fail-open rescue pattern
   - Boot reconciliation via `handle_continue` (non-blocking)
   - Streaming file checksum (no full-file load)
   - Pending marker written BEFORE filesystem swap
   - Node identity file chmod 0o600
   - Watchdog OOBE activation via PubSub
   - check_origin configured for production
   - WiFi connect timeout handles hotspot restart failure

2. `1bfd362b84` — E2E tunnel fix (5 files)
   - Root cause: macOS 26 (Tahoe) blocks non-system binaries from local network
   - Fix: SSH tunnel auto-detection in pi-e2e-preflight.sh
   - All E2E runner scripts pick up tunnel host automatically

3. `efdaa0b958` — Triple review findings (4 files)
   - Invalid mode atom `:error` → `:idle` in wifi/manager.ex
   - Removed no-op `put_status(429)` before redirect in auth_controller
   - Added missing `@impl true` annotations
   - Fixed stale comments (init/1 refs, 30-min timer, sleep rationale)

4. `471176a973` — Re-probe findings (4 files)
   - Version verification in reconcile_pending_update (prevents false-positive)
   - Rollback return values checked everywhere (no silent swallowing)
   - Wizard finalize moved to background Task (prevents LiveView freeze)
   - Watchdog `:check` handler guarded with `active: false` clause

### Stage 6: Triple Review

Ran code-reviewer, silent-failure-hunter, and comment-analyzer in parallel.
Findings:
- 4 code issues (all fixed in commit 3)
- 2 silent failure issues (ETS crash, ignored rollback — both fixed)
- 3 stale comments (all fixed)

### Stage 7: Re-probe

Second edge-case pass on the NEW code found 3 additional issues:
- False-positive reconciliation (version not verified) — fixed
- Wizard finalize blocks LiveView — fixed
- Watchdog check handler missing active guard — fixed

### Stage 8: Harness

Encoded 6 guardrails into AGENTS.md from observed misbehavior patterns:
1. Never ignore return values from fallible operations
2. Never use invalid atoms as sentinel values
3. Always add `@impl true` on ALL callback clauses
4. Guard timer-based handlers with activation flags
5. Never block LiveView processes
6. Use streaming for large file operations on Pi

### Stage 9: Archive (this file)

## What worked well

- **Decomposition by file ownership** prevented merge conflicts across parallel tasks
- **Two-pass edge-cases** caught genuinely different bug classes (design vs implementation)
- **Triple review** caught issues no single reviewer found
- **SSH tunnel workaround** unblocked E2E testing despite macOS 26 local network restrictions
- **ETS fail-open pattern** maintained availability during GenServer restart windows

## What didn't work / lessons learned

1. **macOS 26 local network blocking** was initially misattributed to Tailscale. Spent
   time removing a stale Tailscale peer before discovering the real cause. Lesson: test
   with system binaries first (`/usr/bin/curl`) to isolate OS-level vs app-level issues.

2. **deploy/bundle/ is gitignored** — boot guard script created there was wiped by
   build-release.sh. Lesson: deployment artifacts that need to persist should live in
   source (deploy/scripts/) not in the build output directory.

3. **Elixir `return` keyword** — agent initially wrote `return` for early exit.
   Lesson: already covered in AGENTS.md Elixir guidelines (immutable rebinding).

4. **Flaky async test** — 1/164 failure appeared once, passed on re-run. Async race
   condition, not a regression. Already have a trajectory for this pattern.

## Validation results

- **Unit tests**: 164/164 pass (async: true)
- **Pi verification**: 14/14 checks pass (pre and post-reboot)
- **E2E Mode A smoke**: passes through SSH tunnel
- **Pi reboot cycle**: clean startup, all services healthy

## Files modified (across all commits)

- `lib/clawrig/wifi/manager.ex` — connect timeout, mode atoms
- `lib/clawrig/wifi/watchdog.ex` — OOBE activation, active guards
- `lib/clawrig/gateway/watchdog.ex` — OOBE activation, active guards
- `lib/clawrig/rate_limiter.ex` — ETS fail-open rescue
- `lib/clawrig/updater.ex` — streaming checksum, handle_continue, rollback handling, pending marker, version verification
- `lib/clawrig/node/identity.ex` — file permissions chmod
- `lib/clawrig/wizard/state.ex` — atomic file writes
- `lib/clawrig_web/controllers/auth_controller.ex` — rate limiter integration, removed no-op status
- `lib/clawrig_web/live/wizard_live.ex` — background Task for finalize
- `config/runtime.exs` — check_origin configuration
- `scripts/pi-e2e-preflight.sh` — SSH tunnel auto-detection
- `scripts/run-pi-e2e-*.sh` — tunnel host pickup
- `AGENTS.md` — OTP/GenServer guardrails section
