# Custom alerts implementation plan

**Goal:** Add per-stratagem and per-enemy-category messages, independent cooldowns, flying enemies, and a searchable configuration GUI using current game metadata.

**Architecture:** Keep policy in the independently tested automation fragment. A read-only stratagem catalog supplies stable IDs, localized names, icon hashes and Cooldown-compatible color groups. Dedicated settings subpanels share the existing Armory frame and input handling. Generated enemy facts classify flight before game UnitSize.

**Tech stack:** LuaJIT, existing Stingray UI, Python/lupa tests and official addon ZIP builder.

**Constraints:** Preserve host/client profiles and local-only output. No game memory writes or synthetic gameplay. Blank rule fields inherit defaults; cooldown 0 bypasses the global timer but preserves event deduplication. Catalog scans remain build gated. Existing plugin tabs remain compatible.

## Policy and persistence
- [x] Extend `src/chat_automation.lua` with per-rule lookup, mutation, and bulk update APIs.
- [x] Persist validated rules by stable ID per profile. Tests cover save failure, migration, disabled rules, independent per-player timers, zero bypass, and inherited defaults.
- [x] Prioritize fresh explicit-zero alerts ahead of delayed welcomes and blocked pings; keep role/session checks and native event deduplication.

## Native metadata and enemy coverage
- [x] Add tested `src/stratagem_catalog.lua` scan, lookup, name-key resolution, and resource resolution APIs.
- [x] Resolve stable IDs on existing confirmed marker/call events. Reuse name-based color classification, exact 64-bit icon hashes, and current read guards.
- [x] Generate reviewed hostile enemy facts in `docs/enemy-catalog.json` and `tools/generate_enemy_catalog.py`; wire small/flying classification into `src/ping_events.lua`.
- [x] Document game `UnitSize` enum provenance, missing/non-spottable resources, update limits, and the stratagem catalog grouping and icon behavior in the coverage/reference reports.

## GUI
- [x] Add `src/alert_panel.lua` for separate full-body stratagem/enemy editors opened from settings, preserving plugin tabs.
- [x] Show localized names, safely loaded game icons, search, pagination, color filters, and red/blue/green bulk controls. Keep mission/unknown rows visible separately.
- [x] Expose per-rule enable, separate call/mark templates, cooldown inheritance, variable hints, profile/output/master-switch state, and save failures.
- [x] Test input dispatch, profile separation, bulk updates, and icon loading guards; render and inspect offline layout previews.

## Delivery
- [x] Inline tested fragments, update builder consistency checks, version/docs, and release notes.
- [x] Run targeted tests, the complete unittest suite, and ZIP builder. Verify archive CRC and embedded payload; inspect previews. Final full suite: 381 tests passed; archive and source hashes are recorded in `docs/AUTOMATION-0.8.0-VERIFICATION.md`.
- [ ] Install, publish, and run the manual game checks described in the verification record. No game validation or release publication is claimed by this offline plan run.
