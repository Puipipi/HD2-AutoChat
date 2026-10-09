# Offline panel performance check (0.8.4)

Run from `mods/auto-chat` with Python, the repository's `lupa` test dependency, LuaJIT, and the `v0.8.3` Git tag available:

```powershell
python work/standalone/bench_panel_performance.py
```

The script measures complete `_G.update()` calls in the existing synthetic harness and uses Windows `QueryPerformanceCounter` around each call. It warms each scenario for 1,200 frames, then records 12,000 frames per scenario. Three runs of each variant are interleaved. The legacy variant uses the current `src/auto_chat.lua` with only `panel_signature()` replaced by the v0.8.3 implementation from Git; the cached variant loads the current source unchanged. This keeps all other code identical. The script checks that both variants return the same final signature.

The timer and LuaJIT are real. Game memory, FFI game/native calls, engine APIs, window/input, and GUI drawing are supplied by the offline harness; no game is started. `closed` means the panel is closed, `open` measures a retained panel with no signature changes, and `forced` changes the hint every frame to force redraws. These numbers describe the synthetic harness, not in-game frame time or a 50 μs guarantee.

Machine: Windows 11 build 26100, Intel Core i9-14900HX. Measurements from 2026-10-09:

| Scenario | Legacy median run mean | Cached median run mean | Legacy p95 range | Cached p95 range | Legacy p99 median | Cached p99 median |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Closed | 4.94 μs | 5.37 μs | 3.40–5.80 μs | 3.90–6.10 μs | 110.55 μs | 123.70 μs |
| Open | 25.13 μs | 20.39 μs | 45.80–76.10 μs | 36.20–62.40 μs | 175.65 μs | 157.20 μs |
| Forced redraw | 234.80 μs | 190.54 μs | 293.20–570.80 μs | 331.00–613.70 μs | 938.15 μs | 817.70 μs |

“Median run mean” is the median of the three per-run means. Each p95 range spans the three per-run p95 values; p99 is their median. The open-panel mean improved in this sample, while percentile ranges overlap, closed-panel mean regressed slightly, and forced-redraw tails remain noisy. Treat this as a direction for measurement, not a performance guarantee. The earlier due-only task-sort prototype is omitted because its measured change was not distinguishable from run noise.

An independent repeated benchmark was captured in `work/deploy/perf-panel-cache-0.8.4-20261009.txt` (exit 0). It measured closed-panel median run means 4.81→4.70 μs, retained-open 23.90→17.60 μs, and forced redraw 156.49→203.63 μs. This run's forced-redraw mean regressed, reinforcing that only steady-state panel formatting/allocation is the intended optimization; benchmark variability and stubbed GUI work preclude a real-game frame-time claim.
