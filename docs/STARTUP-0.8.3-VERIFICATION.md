# AutoChat 0.8.3 candidate verification

This candidate clarifies role-targeted preset application, removes the duplicate quick-timer controls and migrates enabled legacy timers into ordinary repeat tasks, adds mission-stratagem-only bulk controls, follows the game language, and adds the separate ordinary-supplies switch. The six verified SEAF shell resources retain the existing building-alert category. This does not establish complete bunker, salute-pod, map-resource, or generic broadcast-location identification; those mappings need real in-game samples.

The game was not launched for this candidate. Chinese in-game IME entry, actual stratagem call-in/ping delivery, ordinary-supplies reporting, and multiplayer output still require the user's test. The offline tests exercise the rules and send path but do not establish those native game events.

## Verification

- Post-fix full suite: `python -B -m unittest discover -s work/standalone/tests -v` ran 466 tests in 101.735 seconds. It reported no assertion failures and one error: Windows returned `PermissionError: [WinError 5]` while the NASM fixture attempted to create a child process. The full output is [tests-0.8.3-postfix.txt](../work/deploy/tests-0.8.3-postfix.txt), with exit code 1 in [tests-0.8.3-postfix.exit](../work/deploy/tests-0.8.3-postfix.exit). The same exact fixture test passed when run alone (`Ran 1 test ... OK`).
- The earlier 466-test run also found a standalone automation fallback assertion introduced by localization; that compatibility issue was fixed and covered by `test_chat_automation.py` (53/53) before the post-fix run. The first output is preserved at [tests-0.8.3.txt](../work/deploy/tests-0.8.3.txt).
- Focused behavior checks passed: preset apply restores a five-second repeat that later sends its saved message; applying a client preset while host is active leaves host tasks untouched; task-stratagem bulk switches affect only rows in the catalog's mission family; English/Chinese objective types and localized panel statuses use the language resolver.
- Final targeted follow-up checks passed: `test_preset_panel.py` ran 10 tests and `test_auto_chat_probe.py` ran 55 tests, both exit 0. Preset-apply feedback now uses a fresh successful session-role sync (unknown role stays explicitly unconfirmed). Runtime diagnostics use FIFO deduplication: the latest 64 distinct signatures are retained, duplicates are suppressed, and an evicted signature can be recorded again. The 466-test full-suite log above predates these narrow changes and remains unchanged.
- `python work/standalone/build_mod.py --validate-only` passed LuaJIT compilation and the build safety gates. The gates confirmed declared FFI calls, live detection, no memory writes, and the README block extracted from source.
- Package verification passed ZIP CRC checks, five-entry layout, manifest label `AutoChat 0.8.3`, and exact equality between the packaged resource entry and `build_addon.entry_source('mods/codex/auto_chat', source)`.

## Package

- ZIP: `work/standalone/dist/AutoChat-0.8.3.zip` (139,909 bytes)
- ZIP SHA-256: `a3648df28a99e33f2b85e43fcd726a30e11d92cd2cf8564c12b7948baa269676`
- Packaged entry SHA-256: `71c64f383bddf13251daa975b291dfa431cfe3c2bf0a5277301924d01875f779`
- Patch payload SHA-256: `15c6fb5703054e9311b3d3af454b0739e062c60bb7e78e7a9aba4c8703912915`

## Minimal in-game checks

1. Open a host preset, apply it to the host configuration, and verify its saved task/template takes effect. Then apply a client preset while host identity is active and confirm the notice names the client target and the host behavior stays active.
2. Type Chinese directly into a stratagem or enemy rule field, save, close/reopen the panel, and verify the text persists. Check that the current stratagem list and `{任务类型}` follow the game's selected language.
3. Mark and call in a stratagem with the alert enabled, then disabled; confirm the setting and runtime status identify which step accepts or rejects it. Check one verified ordinary supply with `普通物资` enabled and disabled.
4. Verify a task-stratagem bulk action changes only mission-family rules, leaving red/blue/green and custom messages unchanged. If convenient, capture a bunker, salute pod, SEAF shell, or map supply and retain its sanitized resource/event identity for catalog follow-up.

Do not infer support for an unobserved resource from a generic location label. New identities should be added only after the event contains a stable resource/name that can be independently verified.
