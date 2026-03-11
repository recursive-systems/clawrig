# Fix flaky async test: post_update_auth_probe_public/1

**Date:** 2026-03-11
**Duration:** ~15 minutes
**Outcome:** success

## Goal

Fix a flaky test failure in `updater_test.exs` that only appeared with specific ExUnit seeds (e.g., 148916) but passed in isolation.

## Approach

1. Ran full suite — 1 failure at seed 148916 in `post_update_auth_probe_public/1`
2. Ran failing test in isolation with `--trace` — passed, confirming test-ordering issue
3. Reproduced deterministically with `--seed 148916`
4. Identified root cause: test was `async: true` but mutated `HOME` via `System.put_env`. Another async test's `on_exit` callback restored `HOME` between setup and assertion, causing `CodexAuth.auth_exists?` to check the real `~/.codex/auth.json`
5. Fixed by making `CodexAuth.auth_path` configurable via app env (matching existing `OpenAICredentials` pattern)
6. Verified fix with original failing seed and multiple random seeds

## Key files modified

- `lib/clawrig/auth/codex_auth.ex` — added `Application.get_env(:clawrig, :codex_auth_path, ...)` to `auth_path/0`
- `test/clawrig/updater_test.exs` — replaced `System.put_env("HOME", ...)` with `Application.put_env(:clawrig, :codex_auth_path, ...)`

## What worked

- Running with the specific failing seed for deterministic reproduction
- Recognizing the isolation-vs-full-suite pattern as a global state race
- Following the existing `auth_profiles_path` app-env pattern for consistency

## What didn't work

- N/A — diagnosis was straightforward once the seed was captured

## Lessons learned

- `System.put_env` is process-global in BEAM — never use it in `async: true` tests
- `Application.get_env` with a configurable path is the safe, idiomatic Elixir pattern for testable file paths
- Always capture the failing seed from CI/test output — it's the key to deterministic repro
- When a test passes alone but fails in suite, check for global state mutation (`System.put_env`, `Application.put_env` on shared keys, ETS writes)

## Related

- `.notes/2026-03-11.md` — decision journal entry for this fix
