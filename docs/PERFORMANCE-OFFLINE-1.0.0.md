# Offline frame-cost check (1.0.0 build 10)

The task scheduler now checks whether any enabled, unfinished task for the active role is due before building and sorting its ordered task list. If none is due, it returns without that allocation and sort. Due tasks still use the existing ordered send path.

The repeatable offline harness is `work/standalone/bench_frame_performance.py`. It loads the current module or a Git source ref, warms each LuaJIT runtime, and measures `_G.update()` in Lua with QueryPerformanceCounter. Each case runs 12,000 measured frames after 1,200 warmup frames, in three fresh runtimes. The GUI, game APIs, and fonts are stubs; the displayed microseconds are harness measurements, not in-game latency. The open redraw case uses an engine-font mock, while closed cases do not draw.

Reproduce the baseline and current runs from the repository root:

```powershell
python -B work/standalone/bench_frame_performance.py --source-ref 5237d9b --runs 3 --frames 12000 --warmup 1200
python -B work/standalone/bench_frame_performance.py --runs 3 --frames 12000 --warmup 1200
```

| Active-role future tasks | Build 9 periodic poll mean / p99 | Build 10 periodic poll mean / p99 | Task sorts per 12,000 frames |
| ---: | ---: | ---: | ---: |
| 100 | 118.56 / 448.90 µs | 73.19 / 305.50 µs | 400 → 0 |
| 1,000 | 605.09 / 1,158.90 µs | 78.49 / 327.20 µs | 400 → 0 |

These periodic figures include the every-30-frame observation work. For 1,000 future tasks, the median steady-frame mean was 2.41 µs before and 1.72 µs after; overall mean was 22.50 µs before and 4.28 µs after. The 100-task overall mean was 5.66 µs before and 4.08 µs after. Closed-empty and open-retained timings varied between runs and do not indicate a material change.

The benchmark prints the loaded source SHA-256 and records per-frame mean, steady mean, periodic mean and p99, overall p99/max, sort counts, native-read counters, GUI draw/measure calls, and GUI create/destroy counts. Logs are in `work/deploy/perf-build10-taskonly-{baseline,current}-3runs-20261010.txt`. A redraw-local wrapped-text cache was tested but not retained; offline measurements did not show a stable gain, and the font mock cannot predict the real engine's text-measurement cost. Build 10 contains no UI-cache change.
