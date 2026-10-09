# AutoChat 0.8.1 startup scan verification

## Change

The 0.8.0 catalog scan called the native localization lookup for every accepted
stratagem row on its first update. The 0.8.1 scan uses the validated internal
English `debug_name` and no longer receives the native localization callback.
Stable IDs, localization keys, resource aliases, rule grouping, category
classification, icon IDs, and automatic discovery remain available. The rule
editor therefore shows English debug names. Live event messages still try the
existing event-time localization path first and use the debug name if that
lookup returns no usable value.

The first catalog scan now logs `stratagem catalog scan begin` and one completion
line with its status. These phases can locate a future fault across the scan
boundary without per-row logging.

## Regression evidence

Before the source change, this focused test failed because the callback was
invoked once for the fixture row:

```text
python -m unittest work.standalone.tests.test_stratagem_catalog.StratagemCatalogTests.test_startup_catalog_scan_does_not_call_native_localization
AssertionError: Lists differ: [2994328991] != []
Ran 1 test
FAILED (failures=1)
```

After the change, `python -m unittest work.standalone.tests.test_stratagem_catalog`
passed all 22 tests. The complete offline suite passed 382 tests in 86.600s.
This verifies that catalog scanning no longer calls the supplied localization
callback and preserves tested row IDs, names, keys, aliases, grouping, variants,
and event-localization priority. It does not establish the game crash's cause.

## Package

`python work/standalone/build_mod.py --output-dir dist` passed LuaJIT compilation,
FFI declaration, read-only, live-detection, README, and archive safety gates.
`dist/AutoChat-0.8.1.zip` contains five CRC-valid entries; its manifest name is
`AutoChat 0.8.1`, its source entry matches the normalized working source exactly,
and its resource companions are empty. The ZIP contains no script-like files.

```text
ZIP size: 114672 bytes
ZIP SHA-256: 18cf90db311a063e5f927b70f2b9c4904e7a21ad006938582fc609a02b2280d3
Raw source SHA-256: 58e942286608d13c9c0c6cf952918b049428ef861d438b537ad23436690dc680
Normalized source-entry SHA-256: b425cada6e571a19d739817a3019fbba7bac11710e17147c4f3f34220297b861
```

## Actual startup check

On 2026-10-09, the 0.8.1 candidate was deployed to the user's normal default
profile and started through Steam. The game remained responsive and reached the
interactive ship bridge. The game initially showed a connection-error dialog;
continuing past it reached the ship arrival sequence. This check validates game
startup, not entry into an online lobby.

The loader log recorded `Startup finished: 73 loaded, 0 failed` and `After
startup: 4 callbacks run, 0 failed`. `AutoChat.log` recorded `AutoChat v0.8.1
starting` at `2026-10-09T11:40:47Z`, then `stratagem catalog scan begin` and
`stratagem catalog scan complete: 战备目录读取就绪（149）` at
`2026-10-09T11:40:48Z`. The extracted deployed resource entry matched the
candidate entry SHA-256 above. The process was still responsive at
`2026-10-09T11:46:31Z`; the latest recorded heartbeat had 27,001 frames,
117,930 reads, 8,421,693 bytes, and 0 errors. No startup crash was observed.

The reported 0.8.0 crash was not reproduced with this candidate; these observations
do not prove its cause. The ship bridge was reached, but short `K` and `Escape`
keypresses sent through the desktop automation produced no visible response, so
panel and native pause-menu behavior remain unverified.
