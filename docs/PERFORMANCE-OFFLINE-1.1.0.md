# Offline performance comparison (AutoChat 1.1.0 candidate)

This is an offline LuaJIT harness result, not a measurement of Helldivers 2 or its native GUI. It drives the production `M.update` path and production retained-panel/catalog code against deterministic synthetic engine and memory boundaries. Native localization, GUI, font, and process memory are fake boundaries; no game process was inspected or controlled.

## Reproducibility

- Harness: `work/standalone/bench_build11_scenarios.py`, with the existing LuaJIT/QPC panel harness.
- Input catalog fixture: `work/standalone/tests/fixtures/stratagem_catalog_20261009.json` (149 rows / 135 rules; Steam build 25480438, game data snapshot 1.007.100 dated 2026-10-09).
- The clock was installed before module load and advanced by 1/60 second per frame. Enabled listeners exercised the production five-second catalog scan cadence. Each measured process used 1,200 warmup frames and 12,000 measured frames; full candidate comparison used three fresh processes per scenario, interleaved build11/candidate.
- `build11` exact source SHA-256: `580B9EF1758AC436AE299FE7FF080C22C5462F27BD1E0F2672E20B86ADB8BF00`.
- Performance candidate source SHA-256: `C507D64650F6179F0B68749C8767367BACE3CD1B19C0CE387030242C575B8966`.
- build11 snapshot: `work/perf-build11-snapshot-20261011/src/auto_chat.lua`; candidate snapshot: `work/perf-catalog-stable-20261011/src/auto_chat.lua`. Raw source-file hashes were taken by the harness. The separate shared-`seen` micro-comparison used the c507 snapshot as “before” and source SHA-256 `59538E944BE872ED00EA7062F974FE10D5DC07E2BE05AB8675C1588949DB8F63` as “after”, with the same fixed-clock harness, three interleaved runs, and only cached retained-panel plus 1,000-future-task scenarios.

## Full build11 to candidate results

Values are medians across three runs. Times are milliseconds per frame (`ms`). All 1,200 warmup frames are excluded from measured statistics. `steady` excludes frames where `frame % 30 == 1`; `periodic` contains those every-30-frame scheduled poll ticks. These poll ticks do not each perform a full catalog scan: the production scan retains its five-second cadence. Percentiles/maxima can be dominated by fake-boundary and harness scheduling costs and are included to prevent the mean from being read as a per-frame guarantee.

| Scenario | build11 mean / steady mean | candidate mean / steady mean | candidate steady p99 / max | candidate periodic mean / p99 / max | Notes |
| --- | ---: | ---: | ---: | ---: | --- |
| Closed, empty | 0.0277 / 0.0028 | 0.0362 / 0.0037 | 0.0235 / 0.2921 | 0.9807 / 10.3754 / 11.2289 | Periodic listener work dominates its mean and tail. |
| Closed, 100 future tasks | 0.0253 / 0.0025 | 0.0396 / 0.0038 | 0.0240 / 0.1940 | 1.0777 / 10.7124 / 11.4627 | No task-sort calls in the measured case. |
| Closed, 1,000 future tasks | 0.0306 / 0.0030 | 0.0353 / 0.0038 | 0.0324 / 0.3748 | 0.9486 / 7.7533 / 9.3138 | Steady work remains below 0.05 ms; periodic work does not. |
| Open, cached names, moving clock | 0.0561 / 0.0299 | 0.0504 / 0.0213 | 0.1805 / 0.6629 | 0.8930 / 9.4224 / 11.3537 | Native lookup calls 39→0; catalog generations 39→0; GUI create/destroy 78→0. |
| Open, cached names, frozen clock | 0.0310 / 0.0238 | 0.0332 / 0.0250 | 0.1642 / 0.6904 | 0.2677 / 1.1140 / 1.2509 | Control case excludes periodic catalog rescan. |
| Open, unresolved names | 0.0832 / 0.0454 | 0.0505 / 0.0219 | 0.1791 / 2.5565 | 0.8788 / 9.2732 / 10.8669 | Name-resolution work remains bounded and continues for unresolved keys. |
| Open, permanent `nil` names | 0.0703 / 0.0341 | 0.0539 / 0.0241 | 0.1554 / 0.7888 | 0.9180 / 9.7010 / 10.6033 | 1,600 bounded native-boundary calls in each run; no successful cache. |
| Open, long Chinese/English rule messages | 0.0815 / 0.0471 | 0.0537 / 0.0256 | 0.2001 / 0.7460 | 0.8508 / 8.7419 / 10.9355 | Exercises real message-field panel rendering with fake text/font boundary. |
| Open, forced dirty draw every frame | 1.1257 / 1.1146 | 0.9387 / 0.9291 | 3.9881 / 13.1498 | 1.2155 / 4.5719 / 5.4981 | Artificial stress case; mean improved 16.6%, not ordinary retained-frame behavior. |

Cold-open and over-budget samples for the two representative retained/closed cases:

| Scenario | build11 cold-open / frames over 0.05 ms | candidate cold-open / frames over 0.05 ms |
| --- | ---: | ---: |
| Closed, 1,000 future tasks | Not applicable / 3.46% | Not applicable / 3.75% |
| Open, cached names, moving clock | 7.8113 ms / 10.29% | 9.5086 ms / 9.12% |

Cold-open is a single measured frame in each fresh process and varied substantially between rounds; these medians do not support a cold-open improvement claim.

## Shared-comparison micro-check

After the full comparison, the unchanged-catalog comparison was adjusted to reuse one identity map while deeply checking all seven captured outputs (including both sides of every map key set). This avoids traversing the same shared row object graph repeatedly while retaining complete content comparison. Across three interleaved runs, cached/moving `periodic_mean` was 1.2052 ms before and 1.1503 ms after; `periodic_p99` was 12.4077 ms before and 11.8835 ms after. The 1,000-future-task case was 1.2227 ms before and 1.1951 ms after periodic mean, with periodic p99 12.1597 ms before and 11.9770 ms after. Steady means changed only slightly (cached 0.0330→0.0332 ms; future-1000 0.0051→0.0052 ms); this small difference is within harness noise and is not claimed as a reliable gain.

The unchanged-snapshot behavior itself is deterministic: generation and published row/index objects stay stable, and panel-name caches survive; changed native/localized names, call payload data, alias additions/removals, failed reads, or a changed base still take the full publish/reset path. Targeted regression tests exercise each of these cases.

## Interpretation and limits

The request for 0.05 ms per frame can only be evaluated for a named scenario and statistic. Several closed-panel steady means and the cached moving steady mean are below 0.05 ms in this synthetic harness. Periodic catalog work, open-panel cold paths, and the artificial dirty-every-frame case exceed that value, and measured maxima reach multiple milliseconds. These results do not establish a hard 0.05 ms frame budget or real-game performance. No live Helldivers 2 test was performed.
