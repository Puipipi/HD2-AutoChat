# AutoChat 0.8.2 candidate verification

## Scope

This candidate addresses the seven reported issues through role-specific, full behavior presets; Chinese stratagem display names; game-window IME input; removal of the obsolete sender-role gate; and stratagem event diagnostics and formatting. Squad chat versus local-only output remains selectable. Legacy preset formats retain the destination role's existing tasks and quick timer when those fields were not saved by the old format. A timer task that was never saved in an older preset cannot be reconstructed.

The game was not launched for this candidate. In-game Chinese typing, stratagem ping/summon delivery, and multiplayer delivery still require the user's test. The existing 0.8.1 bridge-startup observation does not establish those 0.8.2 behaviors.

## Offline evidence

- Full suite: `python -B -m unittest discover -s work/standalone/tests -v` ran 433 tests in 84.560 seconds. It reported no assertion failures and one error: Windows denied `CreateProcess` (`PermissionError: [WinError 5]`) while the NASM fixture test attempted to start `C:\Program Files\mingw64\bin\nasm.exe`. The complete captured output is [tests-0.8.2.txt](../work/deploy/tests-0.8.2.txt). The failure was not skipped or relabeled as a pass. This run preceded the final focused clipboard-owner check and IME recovery-state cleanup.
- The exact NASM fixture test passed independently as part of `python -B -m unittest test_panel_input.PanelInputTest` (19 tests, exit 0). The bytecode-budget subprocess test passed independently (exit 0).
- After the full run, 10 focused role-preset, timer, clipboard ownership, IME readiness, event and gate tests passed. The pending-character tests exercise a queued WM_CHAR arriving before saving a preset and before focus-release; both retain the final character. Clipboard writes require the focused game window as owner. The IME test checks that an unavailable IME context produces a visible panel hint.
- `tools/sync_fragments.py` was run twice; the second run left `src/auto_chat.lua` byte-identical. Both runs produced SHA-256 `b29943a44228171cc96a28652024d31a4816b7e32cc532740cf7d6034d6d0203`.
- `python -B work/standalone/build_mod.py` passed LuaJIT compilation, declaration/call checks, the constrained owned-thunk RW-to-RX protection gate, the in-game README check, and the archive script-file check.

## Package integrity

- Package: `dist/AutoChat-0.8.2.zip` (129,813 bytes), also built at `work/standalone/dist/AutoChat-0.8.2.zip`.
- SHA-256: `68bcb889f427accbbe1c3269959635fe20c3b9146d9188b49cc04578e13756ea`.
- The ZIP has five entries and passes `ZipFile.testzip()`. The resource entry CRC-32 is `7ff83afc`.
- The unpacked resource payload matches the normalized loader entry generated from the current `src/auto_chat.lua` byte-for-byte (398,843 bytes, kind 2). Raw source-file SHA-256 is `b29943a44228171cc96a28652024d31a4816b7e32cc532740cf7d6034d6d0203`; normalized UTF-8 entry SHA-256 is `9ffed740e0cf97350d631005e4b782211e2f3e234914be4d13ddfe531ae8aa9d`.
- The manifest identifies the package as `AutoChat 0.8.2`; the stream and GPU companion entries are empty as expected.

These checks establish offline behavior and package consistency. They do not establish that the user's game accepts the updated controls or that stratagem messages reach the intended recipients.
