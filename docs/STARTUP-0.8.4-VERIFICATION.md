# AutoChat 0.8.4 offline verification

This candidate adds a cached panel signature and retry handling for ping/stratagem events that were refused only for temporary readiness or queue capacity. It does not change the signature's 74-field layout or draw invalidation contract. The queue is bounded at 32 entries: up to 16 non-zero-cooldown entries plus capacity for zero-cooldown urgent entries; accepted messages are never evicted. The event's plugin notification is deduplicated across retries.

No game, keyboard, UI, user preferences, or installed files were touched for this verification. The game's native APIs, window, and GUI are mocked by the offline harness. Real in-game startup, input, event classification, and the 0.05 ms/frame target remain unverified. Bunker/salute-pod identities, ordinary map-resource identities, and generic broadcast locations without entity identity still need real samples.

## Verification evidence

- The panel cache regression was first run before the implementation and failed because `PANEL._signature_cache` was absent. After implementation, focused tests passed for cache reuse, formatted scale/elapsed stability, nil/false transitions, plugin registry changes, and `PANEL.sig=nil` redraw behavior.
- `test_cached_signature_matches_all_74_fields_of_the_previous_implementation` compares the candidate signature against the exact v0.8.3 implementation across default, false/nil, scale, elapsed, and changed-message states. The cache returns the same full signature string; it does not replace it with a version counter.
- The standalone performance benchmark is [bench_panel_performance.py](../work/standalone/bench_panel_performance.py); its method and primary interleaved sample are in [PERFORMANCE-OFFLINE-0.8.4.md](PERFORMANCE-OFFLINE-0.8.4.md). It compares only the legacy panel-signature function with the cache; the due-only scheduler experiment is excluded. The timer is Windows `QueryPerformanceCounter`; LuaJIT is active, but game/native and GUI APIs are stubs.
- An independent repeat was captured at [perf-panel-cache-0.8.4-20261009.txt](../work/deploy/perf-panel-cache-0.8.4-20261009.txt) with exit code [0](../work/deploy/perf-panel-cache-0.8.4-20261009.exit). This sample measured retained-open median run mean 23.90 μs → 17.60 μs, closed 4.81 μs → 4.70 μs, and forced-redraw 156.49 μs → 203.63 μs. Tails overlapped and varied; this does not establish an in-game speedup or the 50 μs target.
- Focused module, event, panel, plugin, and build-gate tests passed: `python -B -m unittest -v test_chat_automation test_stratagem_events test_ping_events test_special_targets test_ping_integration test_auto_chat_probe test_plugin_integration test_panel_interaction test_build_gates` (run from `work/standalone/tests`), 279 tests in 10.056 seconds. The raw output is [tests-0.8.4-targeted.txt](../work/deploy/tests-0.8.4-targeted.txt), exit status [0](../work/deploy/tests-0.8.4-targeted.exit).
- Fragment synchronization was run twice with an unchanged source SHA (`b9bc0a…f2384ef`). `build_mod.py --validate-only` exited 0, checking LuaJIT compilation, FFI call declarations, memory-write restrictions, live detection, and the embedded README block; its captured output is [build-0.8.4-validate.txt](../work/deploy/build-0.8.4-validate.txt). The bytecode budget tool also exited 0; the exact top-level count is 2,348 instructions and 204 stack slots, with the tool noting its build cannot report per-function counts ([output](../work/deploy/bytecode-budget-0.8.4.txt)). Package CRC and entry/source equality are checked separately after ZIP creation.

## Local package

- ZIP: `dist/AutoChat-0.8.4.zip` (142,428 bytes); SHA-256: `ffaeeecf0ffcc9c4711238ba116218ad8ef0c5c46f97e686a0b1c3124c4d146e`.
- The five ZIP entries passed CRC validation; manifest label is `AutoChat 0.8.4`. The embedded addon resource entry exactly matches the builder-normalized source (`f3fbe26a7739130c245fe92b587c44fbc2234daa93d595487b213b26f6650100`). Raw source SHA-256 is `b9bc0abce9e48eefed79f63918daf2175c13330143f8364e155448fefd2384ef`; details are in [package-0.8.4-verification.json](../work/deploy/package-0.8.4-verification.json).
- A copy of the ZIP and SHA-256 sidecar is in the workspace root `dist` directory for local review. No install or deployment was performed.

## User test still needed

Start the candidate in the game, verify the panel opens and changes redraw normally, then produce a real stratagem call-in and ping. If an event is rejected, capture only the sanitized status reason and marker category/action; do not include player names, chat contents, coordinates, or addresses. Confirm ordinary UI input and frame-time behavior in the actual game before making runtime performance or delivery claims.
