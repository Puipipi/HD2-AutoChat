"""Exercise scheduling, persistence and the actual settings hit regions offline."""
import unittest

from test_auto_chat_probe import fresh_image, SOURCE


class ScheduledTasksTest(unittest.TestCase):
    def fresh(self, **options):
        lua, h = fresh_image(**options)
        mod = h.load(SOURCE)
        self.assertTrue(callable(mod.add_task), "settings needs a real task creation path")
        return lua, h, mod

    def test_validation_rejects_bad_time_and_blank_message(self):
        _, _, mod = self.fresh()
        for mode, value, message in (("repeat", "0", "hi"), ("once", "abc", "hi"),
                                     ("daily", "24:01", "hi"), ("daily", "12:60", "hi"),
                                     ("unknown", "30", "hi"), ("repeat", "30", "  ")):
            task, why = mod.add_task("test", mode, value, message, 1000)
            self.assertIsNone(task)
            self.assertTrue(why)
        self.assertEqual(0, len(mod.tasks))

    def test_scheduled_message_formats_local_player_variables_at_send_time(self):
        lua,h,mod = self.fresh()
        lua.globals().test_identity = mod.debug_identity()
        lua.execute("""
            stingray.Network={game_session=function()return 'room' end,peer_id=function()return '76561198000000001' end}
            stingray.GameSession={peers=function()return {'76561198000000001'} end,
                game_session_host=function()return '76561198000000001' end}
            test_identity.lookup=function(peer) return {peer_id=peer,name='Alice',short='A1',color_index=0} end
        """)
        mod.add_task('template','once','5','{玩家名} {缩写} {编号}',1000)
        mod.debug_run_tasks(1005)
        self.assertEqual(h.last_call().arg3_text.rstrip('\0'),'Alice A1 1')

    def test_repeat_and_countdown_have_independent_deadlines(self):
        _, h, mod = self.fresh()
        repeat = mod.add_task("Repeat", "repeat", "30", "first", 1000)
        once = mod.add_task("Once", "once", "45", "second", 1000)
        self.assertIsNotNone(repeat)
        self.assertIsNotNone(once)
        mod.debug_run_tasks(1029)
        self.assertEqual(0, h.call_count())
        mod.debug_run_tasks(1030)
        self.assertEqual("first\0", h.last_call()["arg3_text"])
        mod.debug_run_tasks(1045)
        self.assertEqual("second\0", h.last_call()["arg3_text"])
        self.assertTrue(once["done"])
        mod.debug_run_tasks(1046)
        self.assertEqual(2, h.call_count())
        mod.debug_run_tasks(1200)  # missed intervals coalesce, never catch-up spam
        self.assertEqual(3, h.call_count())
        self.assertEqual(1230, repeat["due"])

    def test_daily_runs_once_per_local_calendar_day(self):
        lua, h, mod = self.fresh()
        lua.execute("""
            os.date = function(fmt, now)
                if fmt == '*t' then
                    return {year=2026, month=10, day=now < 2000 and 8 or 9,
                            hour=21, min=now % 1000 < 30 and 29 or 30}
                end
                return '2026-10-08T00:00:00Z'
            end
        """)
        task = mod.add_task("Daily", "daily", "21:30", "daily message", 1000)
        mod.debug_run_tasks(1029)
        self.assertEqual(0, h.call_count())
        mod.debug_run_tasks(1030)
        mod.debug_run_tasks(1060)
        self.assertEqual(1, h.call_count())
        mod.debug_run_tasks(2030)
        self.assertEqual(2, h.call_count())
        self.assertFalse(task["done"])

    def test_pause_resume_remove_and_normal_send_guards(self):
        _, h, mod = self.fresh(others=0, chat_flag=0)
        task = mod.add_task("Guarded", "once", "5", "guard me", 1000)
        self.assertTrue(mod.toggle_task(task["id"], 1001))
        mod.debug_run_tasks(1010)
        self.assertEqual(0, h.call_count())
        self.assertTrue(mod.toggle_task(task["id"], 1010))
        mod.debug_run_tasks(1015)
        self.assertEqual(0, h.call_count())
        self.assertIn("等待", task["result"])
        self.assertFalse(task["done"])
        self.assertTrue(mod.remove_task(task["id"]))
        self.assertEqual(0, len(mod.tasks))

    def test_persistence_roundtrip_keeps_unicode_and_completed_state(self):
        lua, h, mod = self.fresh()
        task = mod.add_task("提醒%", "once", "5", "集合\t你好%", 1000)
        mod.debug_run_tasks(1005)
        encoded = mod.debug_serialize_tasks()
        self.assertNotIn("集合", encoded)  # bytes are escaped, no executable Lua
        mod.remove_task(task["id"])
        self.assertTrue(mod.debug_restore_tasks(encoded))
        restored = mod.tasks[1]
        self.assertEqual("提醒%", restored["name"])
        self.assertEqual("集合 你好%", restored["message"])
        self.assertTrue(restored["done"])
        mod.debug_run_tasks(2000)
        self.assertEqual(1, h.call_count())

    def test_settings_has_time_and_message_inputs_inside_panel(self):
        lua, _, mod = self.fresh()
        mod.debug_set_open(True)
        lua.execute("for i=1,601 do update() end")
        panel = mod.debug_panel()
        regions = panel["regions"]
        keys = {regions[i]["key"] for i in range(1, len(regions) + 1)}
        self.assertTrue({"task:name", "task:time", "task:message", "task:add",
                         "mode:repeat", "mode:once", "mode:daily"} <= keys, keys)
        geo = mod.debug_geometry(1920, 1080)
        for i in range(1, len(regions) + 1):
            r = regions[i]
            self.assertGreaterEqual(r["y"], geo["y"])
            self.assertLessEqual(r["y"] + r["h"], geo["y"] + geo["h"] + 1)

    def test_draft_typing_does_not_change_an_existing_task(self):
        lua, h, mod = self.fresh()
        task = mod.add_task("Existing", "repeat", "30", "original", 1000)
        panel = mod.debug_panel()
        panel["edit_field"], panel["editing"], panel["edit_text"] = "message", True, ""
        h.user32.set_key(0x4B, True)  # K must be text while a field owns focus
        mod.debug_set_open(True)
        lua.execute("for i=1,601 do update() end")
        self.assertTrue(mod.panel_open)
        self.assertEqual("original", task["message"])
        h.user32.set_key(0x4B, False)
        self.assertIn("k", panel["edit_text"])

    def test_chinese_clipboard_paste_is_utf8_and_closes_clipboard(self):
        lua, h, mod = self.fresh()
        lua.execute(r'''
            local ffi = require('ffi')
            local u, k = ffi.load('user32'), ffi.load('kernel32')
            local h = ...
            h.bytes(0x700000000, string.char(0x60,0x4f,0x7d,0x59,0,0))
            h.clip_closed = 0
            u.OpenClipboard = function() return 1 end
            u.CloseClipboard = function() h.clip_closed = h.clip_closed + 1 return 1 end
            u.GetClipboardData = function() return ffi.cast('void *', 0x700000000) end
            k.GlobalLock = function(ptr) return ptr end
            k.GlobalUnlock = function() return 1 end
            k.GlobalSize = function() return 6 end
        ''', h)
        mod.debug_set_editing(True)
        mod.debug_set_edit_buffer("")
        h.user32.set_key(0x11, True)
        h.user32.set_key(0x56, True)
        value, _ = mod.debug_edit_text(1)
        self.assertEqual("你好", value)
        self.assertEqual(1, h.clip_closed)

    def test_form_clicks_create_a_persisted_task_and_cancel_keeps_draft(self):
        lua, h, mod = self.fresh()
        mod.debug_set_open(True)
        lua.execute("for i=1,601 do update() end")

        def click(key):
            regions = mod.debug_panel()["regions"]
            r = next(regions[i] for i in range(1, len(regions) + 1) if regions[i]["key"] == key)
            h.mouse_x = r["x"] + r["w"] / 2
            h.mouse_y = 1080 - (r["y"] + r["h"] / 2)
            h.user32.set_key(0x01, True)
            lua.eval("update()")
            h.user32.set_key(0x01, False)
            lua.eval("update()")

        for field, value in (("name", "My event"), ("time", "17"), ("message", "你好")):
            click("task:" + field)
            mod.debug_set_edit_buffer(value)
        # Adding must commit the still-focused message, not lose the last field.
        click("task:add")
        self.assertEqual(1, len(mod.tasks))
        task = mod.tasks[1]
        self.assertEqual("My event", task["name"])
        self.assertEqual("17", task["time"])
        self.assertEqual("你好", task["message"])
        self.assertIn("AutoChatTasks1", h.log_text())
        click("task:message")
        mod.debug_set_edit_buffer("discard me")
        h.user32.set_key(0x1B, True)
        lua.eval("update()")
        h.user32.set_key(0x1B, False)
        self.assertIsNone(mod.debug_panel()["edit_field"])
        self.assertEqual("你好", task["message"])

    def test_save_failure_does_not_claim_task_was_added(self):
        lua, _, mod = self.fresh()
        lua.execute("""
            local old = io.open
            io.open = function(path, mode)
                if tostring(path):find('tasks.txt',1,true) then return nil end
                return old(path, mode)
            end
        """)
        task, why = mod.add_task("Fail", "repeat", "30", "message", 1000)
        self.assertIsNone(task)
        self.assertIn("保存失败", why)
        self.assertEqual(0, len(mod.tasks))

    def test_corrupt_saved_tasks_do_not_replace_good_tasks(self):
        _, _, mod = self.fresh()
        mod.add_task("Keep", "repeat", "30", "message", 1000)
        self.assertFalse(mod.debug_restore_tasks("AutoChatTasks1\nbroken\n"))
        self.assertEqual("Keep", mod.tasks[1]["name"])

    def test_live_update_uses_elapsed_wall_time_not_frame_count(self):
        lua, h, mod = self.fresh()
        lua.execute("os.time = function() return TEST_NOW end; TEST_NOW = 1000")
        mod.add_task("Real seconds", "repeat", "30", "wall time", 1000)
        lua.execute("for i=1,10000 do update() end")
        self.assertEqual(0, h.call_count(), "many frames are not elapsed seconds")
        lua.execute("TEST_NOW = 1030; for i=1,30 do update() end")
        self.assertEqual(1, h.call_count(), "30 real seconds must trigger at any FPS")

    def test_task_file_is_loaded_on_boot_without_rearming_completed_tasks(self):
        _, _, mod = self.fresh()
        mod.add_task("Restore", "once", "5", "once", 1000)
        mod.debug_run_tasks(1005)
        encoded = mod.debug_serialize_tasks()
        lua, h = fresh_image()
        lua.globals().SAVED_TASKS = encoded
        lua.execute("""
            local old = io.open
            io.open = function(path, mode)
                if tostring(path):find('tasks.txt',1,true) and mode == 'r' then
                    return {read=function() return SAVED_TASKS end, close=function() end}
                end
                return old(path, mode)
            end
        """)
        restored = h.load(SOURCE)
        self.assertEqual(1, len(restored.tasks))
        self.assertTrue(restored.tasks[1]["done"])
        restored.debug_run_tasks(2000)
        self.assertEqual(0, h.call_count())

    def test_old_enabled_timer_becomes_visible_task(self):
        lua, h = fresh_image()
        lua.execute("""
            local old = io.open
            io.open = function(path, mode)
                if tostring(path):find('panel.txt',1,true) and mode == 'r' then
                    return {read=function() return 'timer_on=yes\\ninterval=45\\nmessage=old message\\n' end,
                            close=function() end}
                end
                return old(path, mode)
            end
        """)
        mod = h.load(SOURCE)
        self.assertEqual(1, len(mod.tasks), "old enabled timer must be visible in settings")
        self.assertEqual("45", mod.tasks[1]["time"])
        self.assertEqual("old message", mod.tasks[1]["message"])
        self.assertFalse(mod.debug_cfg()["timer_on"], "no second hidden timer may keep firing")

    def test_full_task_pages_have_no_overlap_at_common_resolutions(self):
        for rw, rh in ((1280, 720), (1920, 1080), (3840, 2160)):
            lua, h, mod = self.fresh()
            h.res_w, h.res_h = rw, rh
            for i in range(32):
                mod.add_task("Event " + str(i), "repeat", "30", "message", 10000000000)
            mod.debug_set_open(True)
            for page in (1, 5):
                mod.debug_panel()["task_page"] = page
                lua.execute("for i=1,601 do update() end")
                geo = mod.debug_geometry(rw, rh)
                regions = mod.debug_panel()["regions"]
                boxes = [regions[i] for i in range(1, len(regions) + 1)]
                for r in boxes:
                    self.assertGreaterEqual(r["y"], geo["y"] - 1)
                    self.assertLessEqual(r["y"] + r["h"], geo["y"] + geo["h"] + 1)
                    self.assertGreaterEqual(r["x"], geo["x"] - 1)
                    self.assertLessEqual(r["x"] + r["w"], geo["x"] + geo["w"] + 1)
                for i, a in enumerate(boxes):
                    for b in boxes[i + 1:]:
                        dx = min(a["x"] + a["w"], b["x"] + b["w"]) - max(a["x"], b["x"])
                        dy = min(a["y"] + a["h"], b["y"] + b["h"]) - max(a["y"], b["y"])
                        self.assertFalse(dx > 1 and dy > 1, (rw, rh, a["key"], b["key"]))

    def test_failed_deadline_persistence_cannot_send_then_repeat_after_restart(self):
        lua, h, mod = self.fresh()
        task = mod.add_task("Once", "once", "5", "only once", 1000)
        lua.execute("""
            local old = io.open
            io.open = function(path, mode)
                if tostring(path):find('tasks.txt',1,true) then return nil end
                return old(path, mode)
            end
        """)
        mod.debug_run_tasks(1005)
        self.assertEqual(0, h.call_count(), "a one-shot must persist its attempt before sending")
        self.assertFalse(task["done"])
        self.assertIn("保存失败", task["result"])

    def test_failed_atomic_replace_does_not_add_task(self):
        lua, _, mod = self.fresh()
        lua.execute("require('ffi').load('kernel32').MoveFileExA = function() return 0 end")
        result = mod.add_task("Fail", "once", "5", "message", 1000)
        self.assertIsInstance(result, tuple, "failed file replacement must return an error")
        task, why = result
        self.assertIsNone(task)
        self.assertIn("保存失败", why)
        self.assertEqual(0, len(mod.tasks))

    def test_migration_failure_preserves_legacy_file_for_next_boot(self):
        lua, h = fresh_image()
        lua.execute("""
            local old = io.open
            io.open = function(path, mode)
                if tostring(path):find('panel.txt',1,true) and mode == 'r' then
                    return {read=function() return 'timer_on=yes\\ninterval=45\\nmessage=keep me\\n' end,
                            close=function() end}
                end
                if tostring(path):find('tasks.txt',1,true) then return nil end
                return old(path, mode)
            end
        """)
        mod = h.load(SOURCE)
        written = h.written()
        panel_writes = [written[i]["text"] for i in range(1, len(written) + 1)
                        if "panel.txt" in written[i]["path"]]
        self.assertEqual([], panel_writes, "migration failure must retain the old configuration")
        self.assertFalse(mod.debug_cfg()["timer_on"], "hidden legacy timer is suspended this session")


if __name__ == "__main__":
    unittest.main()
