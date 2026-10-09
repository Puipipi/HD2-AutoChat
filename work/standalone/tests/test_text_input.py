from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[5]
MODULE = ROOT / "mods/auto-chat/src/text_input.lua"


def make_input(capacity=64):
    from lupa.luajit21 import LuaRuntime

    lua = LuaRuntime(unpack_returned_tuples=True)
    factory = lua.execute(MODULE.read_text(encoding="utf-8") + "\nreturn build_text_input")
    return lua, factory(capacity)


def lua_events(lua, events):
    return lua.table_from([lua.table_from(event) for event in events])


def actions(result):
    return list(result.values())


class TextInputQueueTest(unittest.TestCase):
    def test_decodes_unicode_wm_char_and_keeps_surrogate_pair_across_drains(self):
        lua, editor = make_input()
        first = editor.consume(lua_events(lua, [{"message": 0x102, "wparam": 0xD83D, "lparam": 0}]))
        self.assertEqual([], list(first))
        second = editor.consume(lua_events(lua, [{"message": 0x102, "wparam": 0xDE00, "lparam": 0}]))
        self.assertEqual([("text", "😀")], [(event["kind"], event["value"]) for event in actions(second)])

    def test_unichar_uses_scalar_and_rejects_invalid_surrogates(self):
        lua, editor = make_input()
        result = editor.consume(lua_events(lua, [
            {"message": 0x109, "wparam": 0x1F642, "lparam": 0},
            {"message": 0x109, "wparam": 0xD800, "lparam": 0},
        ]))
        self.assertEqual([("text", "🙂")], [(event["kind"], event["value"]) for event in actions(result)])

    def test_enter_and_escape_are_ordered_and_enter_during_composition_is_not_submit(self):
        lua, editor = make_input()
        events = editor.consume(lua_events(lua, [
            {"message": 0x10D, "wparam": 0, "lparam": 0},  # WM_IME_STARTCOMPOSITION
            {"message": 0x101, "wparam": 0x0D, "lparam": 1 << 31},
            {"message": 0x100, "wparam": 0x0D, "lparam": 0},
            {"message": 0x10E, "wparam": 0, "lparam": 0},  # WM_IME_ENDCOMPOSITION
            {"message": 0x101, "wparam": 0x0D, "lparam": 1 << 31},
            {"message": 0x100, "wparam": 0x0D, "lparam": 0},
            {"message": 0x100, "wparam": 0x1B, "lparam": 0},
        ]))
        self.assertEqual(["ime_start", "ime_end", "submit", "cancel"], [event["kind"] for event in actions(events)])

    def test_repeated_keydown_is_ignored_but_distinct_edges_are_preserved(self):
        lua, editor = make_input()
        result = editor.consume(lua_events(lua, [
            {"message": 0x100, "wparam": 0x0D, "lparam": 0},
            {"message": 0x100, "wparam": 0x0D, "lparam": 1 << 30},
            {"message": 0x101, "wparam": 0x0D, "lparam": 1 << 31},
            {"message": 0x100, "wparam": 0x0D, "lparam": 0},
        ]))
        self.assertEqual(["submit", "submit"], [event["kind"] for event in actions(result)])

    def test_overflow_discards_batch_and_pending_surrogate(self):
        lua, editor = make_input(capacity=2)
        editor.consume(lua_events(lua, [{"message": 0x102, "wparam": 0xD83D, "lparam": 0}]))
        result = editor.consume(lua_events(lua, [
            {"message": 0x102, "wparam": 0xDE00, "lparam": 0},
            {"message": 0x102, "wparam": ord("x"), "lparam": 0},
            {"message": 0x102, "wparam": ord("y"), "lparam": 0},
        ]), True)
        self.assertEqual(["reset"], [event["kind"] for event in actions(result)])
        self.assertTrue(editor.status()["overflow"])
        editor.reset()
        self.assertFalse(editor.status()["overflow"])
        self.assertEqual([("text", "z")], [(e["kind"], e["value"]) for e in actions(editor.consume(lua_events(lua, [{"message": 0x102, "wparam": ord("z"), "lparam": 0}])) )])

    def test_control_characters_are_actions_not_inserted_text(self):
        lua, editor = make_input()
        result = editor.consume(lua_events(lua, [
            {"message": 0x102, "wparam": 0x08, "lparam": 0},
            {"message": 0x102, "wparam": 0x0D, "lparam": 0},
            {"message": 0x102, "wparam": 0x1B, "lparam": 0},
            {"message": 0x102, "wparam": 0x09, "lparam": 0},
            {"message": 0x100, "wparam": 0x0D, "lparam": 0},
            {"message": 0x101, "wparam": 0x0D, "lparam": 1 << 31},
            {"message": 0x100, "wparam": 0x1B, "lparam": 0},
            {"message": 0x102, "wparam": 0x16, "lparam": 0},
            {"message": 0x102, "wparam": 0x01, "lparam": 0},
            {"message": 0x102, "wparam": 0x18, "lparam": 0},
            {"message": 0x102, "wparam": 0x03, "lparam": 0},
        ]))
        self.assertEqual(["backspace", "submit", "cancel", "paste", "select_all", "cut", "copy"],
                         [event["kind"] for event in actions(result)])

    def test_control_keydown_and_translated_char_are_one_action_even_across_ime_end(self):
        lua, editor = make_input()
        result = editor.consume(lua_events(lua, [
            {"message": 0x10D, "wparam": 0, "lparam": 0},
            {"message": 0x100, "wparam": 0x0D, "lparam": 0},
            {"message": 0x10E, "wparam": 0, "lparam": 0},
            {"message": 0x102, "wparam": 0x0D, "lparam": 0},
            {"message": 0x101, "wparam": 0x0D, "lparam": 1 << 31},
            {"message": 0x100, "wparam": 0x0D, "lparam": 0},
            {"message": 0x102, "wparam": 0x0D, "lparam": 0},
        ]))
        self.assertEqual(["ime_start", "ime_end", "submit"], [event["kind"] for event in actions(result)])

    def test_wm_char_repeat_count_repeats_printable_and_backspace_with_a_bound(self):
        lua, editor = make_input()
        result = editor.consume(lua_events(lua, [
            {"message": 0x102, "wparam": ord("a"), "lparam": 3},
            {"message": 0x102, "wparam": 0x08, "lparam": 2},
            {"message": 0x102, "wparam": ord("b"), "lparam": 500},
        ]))
        self.assertEqual([("text", "a")] * 3 + ["backspace"] * 2 + [("text", "b")] * 32,
                         [event["kind"] if event["kind"] != "text" else (event["kind"], event["value"])
                          for event in actions(result)])

    def test_composition_backspace_does_not_delete_committed_field_text(self):
        lua, editor = make_input()
        result = editor.consume(lua_events(lua, [
            {"message": 0x10D, "wparam": 0, "lparam": 0},
            {"message": 0x102, "wparam": 0x08, "lparam": 1},
            {"message": 0x10E, "wparam": 0, "lparam": 0},
        ]))
        self.assertEqual(["ime_start", "ime_end"], [event["kind"] for event in actions(result)])

if __name__ == "__main__":
    unittest.main()
