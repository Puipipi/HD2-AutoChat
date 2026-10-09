# AutoChat 0.8.5 offline verification

This candidate adds one exact-resource fallback for a user-confirmed dropped pod / Super Earth cache mark. When the native marker uses the generic location name, resource `0ABED3586E397289` is displayed as `坠落舱`. This is an AutoChat-maintained contextual label, not an official game localization; it applies only to this exact resource.

The sanitized user sample was a direct target event (`kind=10`, resource `0ABED3586E397289`, generic localization key `3585962803`, and a valid identity link). The user had just marked the Salute pod. The static asset listing at `work/eagle-stingray-research/stingray-archive-list.txt:93034-93035` identifies the exact hash as `super_earth_cache.physics` / `.unit`. No actor, player, pointer, or address data is included here. Native-specific localized text continues to take precedence over the fallback.

This change does not infer names for other cache resources or unlinked map objects. The user reported that, beside a bunker, the game did not offer a native target point to mark. There is therefore no reliable marker entry for AutoChat to classify in that case; this does not establish that every bunker is unmarkable. The user confirmed that the tower-top broadcast marker works through the existing path and that the generic tower-base point should remain unsupported; this candidate does not change broadcast handling. The six previously verified SEAF shell resources remain on the existing building-alert path.

## Offline verification

- `test_special_targets` checks exact lookup for the new hash and rejects unknown/ambiguous resources.
- `test_ping_events` exercises the native marker reader and fallback classification.
- `test_confirmed_drop_pod_target_survives_host_formatting_and_native_send` sends the classified event through the host message queue and the mocked game sender, asserting the delivered text contains `坠落舱` and excludes `特殊地点`.
- No game, keyboard, UI, user preferences, installed files, or remote release actions were used for this candidate. The test sender is a harness; actual in-game delivery remains unverified.

## Package receipt

The focused offline run covered `test_special_targets`, `test_ping_events`, `test_ping_integration`, and `test_build_gates`: 221 tests passed in 9.405 seconds. The exact command was `python -B -m unittest -v test_special_targets test_ping_events test_ping_integration test_build_gates` from `work/standalone/tests`; raw output and exit code are in `work/deploy/tests-0.8.5-focused.txt` and `work/deploy/tests-0.8.5-focused.exit`.

`python -B work/standalone/build_mod.py --validate-only` and the package build both exited 0. LuaJIT compiled 441,583 bytes; the FFI and source gates passed. The final sync was idempotent (source SHA-256 `2a39fef734c1e5537cfb1813f77d4a044348cb3be9d2686c048514bc9d2c8d06` on both runs). The final archive contains five entries, passes CRC validation, declares AutoChat 0.8.5, and its embedded source bytes match the normalized current source entry.

Package: `dist/AutoChat-0.8.5.zip`, 143,363 bytes, SHA-256 `e87c17f49ac723985da558156ba3d917154d344a0c50c9e07229bf6dfefcaa09`. The package check details are in `work/deploy/package-0.8.5-verification.json`; the adjacent `.sha256` file is the checksum sidecar.
