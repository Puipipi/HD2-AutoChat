"""Exercise scheduling, persistence and the actual settings hit regions offline."""
import unittest

from test_auto_chat_probe import fresh_image, SOURCE


class ScheduledTasksTest(unittest.TestCase):
    def fresh(self, **options):
        lua, h = fresh_image(**options)
        mod = h.load(SOURCE)
        self.assertTrue(callable(mod.add_task), "settings needs a real task creation path")
        return lua, h, mod

    def test_enabled_quick_timer_migrates_once_to_role_scoped_repeat_task(self):
        _,_,mod=self.fresh();a=mod.debug_automation()
        self.assertTrue(a.set('quick_timer_enabled',True,'host')[0])
        self.assertTrue(a.set('quick_timer_interval',5,'host')[0])
        self.assertTrue(a.set('quick_timer_message','host quick fixture','host')[0])
        self.assertTrue(a.set('quick_timer_enabled',True,'client')[0])
        self.assertTrue(a.set('quick_timer_interval',9,'client')[0])
        self.assertTrue(a.set('quick_timer_message','client quick fixture','client')[0])
        self.assertIsNotNone(mod.add_task('Existing host task','repeat','20','existing',1000,'host'))
        self.assertTrue(mod.debug_migrate_quick_timer('host'))
        self.assertTrue(mod.debug_migrate_quick_timer('client'))
        self.assertTrue(mod.debug_migrate_quick_timer('host'))
        self.assertFalse(a.profile('host').quick_timer_enabled)
        self.assertFalse(a.profile('client').quick_timer_enabled)
        migrated=[mod.tasks[i] for i in range(1,len(mod.tasks)+1)
                  if mod.tasks[i].name=='旧版快捷定时' and mod.tasks[i].profile=='host']
        self.assertEqual(1,len(migrated))
        self.assertEqual(('repeat','5','host quick fixture'),
                         (migrated[0].mode,migrated[0].time,migrated[0].message))
        self.assertEqual(2,len([mod.tasks[i] for i in range(1,len(mod.tasks)+1)
                                if mod.tasks[i].profile=='host']))
        self.assertEqual(1,len([mod.tasks[i] for i in range(1,len(mod.tasks)+1)
                                if mod.tasks[i].profile=='client']))

    def test_validation_rejects_bad_time_and_blank_message(self):
        _, _, mod = self.fresh()
        for mode, value, message in (("repeat", "0", "hi"), ("once", "abc", "hi"),
                                     ("daily", "24:01", "hi"), ("daily", "12:60", "hi"),
                                     ("unknown", "30", "hi"), ("repeat", "30", "  ")):
            task, why = mod.add_task("test", mode, value, message, 1000)
            self.assertIsNone(task)
            self.assertTrue(why)
        self.assertEqual(0, len(mod.tasks))

    def test_more_than_32_tasks_roundtrip_without_truncation(self):
        lua, h, mod = self.fresh()
        for i in range(33):
            task = mod.add_task(f"Task {i}", "repeat", str(5 + i), f"Message {i}", 1000, "host")
            self.assertIsNotNone(task, f"task {i} was rejected")
        serialized = mod.debug_serialize_tasks()
        self.assertTrue(mod.debug_restore_tasks(serialized))
        self.assertEqual(33, len(mod.tasks))
        for i in range(1, 34):
            self.assertEqual((f"Task {i-1}", f"Message {i-1}", 5+i-1),
                             (mod.tasks[i].name, mod.tasks[i].message, mod.tasks[i].seconds))
        path = "C:/fake/CowboyBingus/Helldivers2/AutoChat/tasks.txt"
        h.virtual_files[path] = serialized
        restarted_lua, restarted_h = fresh_image()
        restarted_h.virtual_files[path] = serialized
        restarted = restarted_h.load(SOURCE)
        self.assertEqual(33, len(restarted.tasks), "file startup must restore every task")
        self.assertEqual("Message 32", restarted.tasks[33].message)

    def test_task_startup_reads_complete_file_above_old_65k_limit(self):
        lua, h = fresh_image()
        rows = ["AutoChatTasks1"]
        message = "x" * 200
        for i in range(1, 301):
            rows.append(f"{i}\trepeat\t5\t1\t0\t1005\t-\tTask {i}\t{message}\thost")
        serialized = ("\n".join(rows) + "\n").encode("ascii").decode("ascii")
        self.assertGreater(len(serialized), 65536)
        path = "C:/fake/CowboyBingus/Helldivers2/AutoChat/tasks.txt"
        h.virtual_files[path] = serialized
        mod = h.load(SOURCE)
        self.assertEqual(300, len(mod.tasks))
        self.assertEqual("Task 300", mod.tasks[300].name)
        self.assertEqual(message, mod.tasks[300].message)
        exported = mod.debug_automation().export_profile("host", mod.profile_tasks("host"))
        self.assertIn("task_count=300", exported)

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
        self.assertEqual(h.last_call().arg3_text.rstrip('\0'),'\n[Alice] A1 1')

    def test_named_preset_roundtrips_behavior_and_role_task_definitions(self):
        lua, _, mod = self.fresh()
        automation = mod.debug_automation()
        library = mod.debug_preset_library()
        host = mod.add_task('Host reminder', 'repeat', '5', 'host fixture', 1000, 'host')
        client = mod.add_task('Client reminder', 'once', '9', 'client fixture', 2000, 'client')
        self.assertIsNotNone(host)
        self.assertIsNotNone(client)
        self.assertTrue(automation.set('ping', True, 'host')[0])
        self.assertTrue(automation.set('welcome_message', 'host welcome fixture', 'host')[0])
        self.assertTrue(automation.set('output', 'squad', 'host')[0])
        self.assertTrue(automation.set('cooldown', 17, 'host')[0])
        self.assertTrue(automation.set('quick_timer_enabled', True, 'host')[0])
        self.assertTrue(automation.set('quick_timer_interval', 5, 'host')[0])
        self.assertTrue(automation.set('quick_timer_message', 'host quick fixture', 'host')[0])
        self.assertTrue(mod.debug_migrate_quick_timer('host'))
        self.assertTrue(automation.set('quick_timer_enabled', False, 'client')[0])
        self.assertTrue(automation.set('quick_timer_message', 'client quick fixture', 'client')[0])
        self.assertTrue(automation.set_rule('stratagem', 4119049995, 'mark_message', 'host mark fixture', 'host')[0])
        self.assertTrue(automation.set_rule('stratagem', 4119049995, 'call_message', 'host call fixture', 'host')[0])
        self.assertTrue(automation.set_rule('stratagem', 4119049995, 'cooldown', 0, 'host')[0])
        self.assertTrue(automation.set_rule('stratagem', 4119049995, 'enabled', False, 'host')[0])
        saved = library.save('host full snapshot', 'host')
        self.assertTrue(saved[0], saved[1])
        preset_id = saved[2]

        # Applying the preset replaces only host task definitions. It never
        # restores the old due timestamp or reuses a mutable task object.
        self.assertTrue(mod.remove_task(host.id))
        replacement = mod.add_task('Temporary', 'once', '40', 'temporary', 3000, 'host')
        self.assertIsNotNone(replacement)
        self.assertTrue(automation.set('quick_timer_enabled', False, 'host')[0])
        self.assertTrue(automation.set('quick_timer_interval', 55, 'host')[0])
        self.assertTrue(automation.set('quick_timer_message', 'mutated', 'host')[0])
        lua.execute('os.time=function() return 5000 end')
        self.assertTrue(library.apply(preset_id, 'host'))
        self.assertEqual(True, automation.profile('host').ping)
        self.assertEqual('host welcome fixture', automation.profile('host').welcome_message)
        self.assertEqual('squad', automation.profile('host').output)
        self.assertEqual(17, automation.profile('host').cooldown)
        self.assertFalse(automation.profile('host').quick_timer_enabled,
                         'the retired sender remains disabled')
        self.assertFalse(automation.profile('client').quick_timer_enabled)
        self.assertEqual('client quick fixture', automation.profile('client').quick_timer_message)
        self.assertFalse(automation.rule('stratagem', 4119049995, 'host').enabled)
        self.assertEqual('host mark fixture', automation.rule('stratagem', 4119049995, 'host').mark_message)
        self.assertEqual('host call fixture', automation.rule('stratagem', 4119049995, 'host').call_message)
        self.assertEqual(0, automation.rule('stratagem', 4119049995, 'host').cooldown)
        self.assertEqual(3, len(mod.tasks))
        migrated=next(mod.tasks[i] for i in range(1,len(mod.tasks)+1)
                      if mod.tasks[i].name=='旧版快捷定时' and mod.tasks[i].profile=='host')
        self.assertEqual(('repeat','5','host quick fixture'),
                         (migrated.mode,migrated.time,migrated.message))
        restored = next(mod.tasks[i] for i in range(1, len(mod.tasks) + 1)
                        if mod.tasks[i].profile == 'host')
        self.assertEqual(('Host reminder', 'repeat', '5', 'host fixture', 'host'),
                         (restored.name, restored.mode, restored.time, restored.message, restored.profile))
        self.assertEqual(5005, restored.due)
        self.assertNotEqual(host.id, restored.id)
        self.assertEqual('client fixture', next(mod.tasks[i].message for i in range(1, len(mod.tasks) + 1)
                                                if mod.tasks[i].profile == 'client'))

        restored.message = 'mutated after load'
        self.assertTrue(library.apply(preset_id, 'host'))
        restored_again = next(mod.tasks[i] for i in range(1, len(mod.tasks) + 1)
                              if mod.tasks[i].profile == 'host')
        self.assertEqual('host fixture', restored_again.message)
        self.assertEqual(5005, restored_again.due)

    def test_applying_named_preset_changes_the_task_that_later_sends(self):
        lua,h,mod=self.fresh()
        library=mod.debug_preset_library()
        self.assertTrue(mod.add_task('Preset repeat','repeat','5','saved behavior message',1000,'host'))
        saved=library.save('send behavior','host')
        self.assertTrue(saved[0],saved[1]);preset_id=saved[2]
        self.assertTrue(mod.remove_task(mod.tasks[1].id))
        self.assertTrue(mod.add_task('Temporary','once','60','temporary',2000,'host'))
        lua.execute('os.time=function() return 5000 end')
        self.assertTrue(library.apply(preset_id,'host'))
        restored=mod.tasks[1]
        self.assertEqual(('repeat',5,'saved behavior message'),
                         (restored.mode,restored.seconds,restored.message))
        mod.debug_run_tasks(5005)
        self.assertEqual(1,h.call_count())
        self.assertEqual('\nsaved behavior message\0',h.last_call()['arg3_text'])

    def test_applying_client_preset_while_host_is_active_only_replaces_client_tasks(self):
        _,_,mod=self.fresh();library=mod.debug_preset_library()
        host=mod.add_task('Host untouched','repeat','17','host stays',1000,'host')
        client=mod.add_task('Client saved','repeat','5','client saved',1000,'client')
        self.assertIsNotNone(host);self.assertIsNotNone(client)
        saved=library.save('client schedule','client')
        self.assertTrue(saved[0],saved[1])
        self.assertTrue(mod.remove_task(client.id))
        replacement=mod.add_task('Client edited','once','60','edited client',2000,'client')
        self.assertIsNotNone(replacement)
        self.assertEqual('host',mod.debug_automation().state.active_role)

        self.assertTrue(library.apply(saved[2],'client'))
        host_after=next(t for i in range(1,len(mod.tasks)+1)
                        if (t:=mod.tasks[i]).profile=='host')
        client_after=next(t for i in range(1,len(mod.tasks)+1)
                          if (t:=mod.tasks[i]).profile=='client')
        self.assertEqual(('Host untouched','repeat','17','host stays'),
                         (host_after.name,host_after.mode,host_after.time,host_after.message))
        self.assertEqual(('Client saved','repeat','5','client saved'),
                         (client_after.name,client_after.mode,client_after.time,client_after.message))

    def test_applied_daily_task_waits_until_next_day_when_time_has_passed(self):
        lua, h, mod = self.fresh()
        library = mod.debug_preset_library()
        lua.execute("""
            os.date = function(fmt, now)
                if fmt == '*t' then
                    return {year=2026, month=10, day=9, hour=21, min=45, sec=0}
                end
                return '2026-10-09'
            end
            os.time = function() return 5000 end
        """)
        mod.add_task('Daily snapshot', 'daily', '21:30', 'daily fixture', 1000, 'host')
        saved = library.save('daily snapshot', 'host')
        self.assertTrue(saved[0], saved[1])
        self.assertTrue(mod.remove_task(mod.tasks[1].id))

        self.assertTrue(library.apply(saved[2], 'host'))
        restored = mod.tasks[1]
        self.assertEqual('2026-10-09', restored.last_day)
        mod.debug_run_tasks(5000)
        self.assertEqual(0, h.call_count(), 'applying after the daily time must not catch up immediately')

        lua.execute("os.date = function(fmt, now) if fmt == '*t' then return {year=2026,month=10,day=10,hour=21,min=30,sec=0} end return '2026-10-10' end")
        mod.debug_run_tasks(6000)
        self.assertEqual(1, h.call_count(), 'the same rule should run at the next day’s scheduled time')

    def test_profile_write_failure_rolls_back_task_memory_and_file(self):
        lua, h, mod = self.fresh()
        library = mod.debug_preset_library()
        existing = mod.add_task('Keep task', 'repeat', '30', 'keep', 1000, 'host')
        before_memory = mod.debug_serialize_tasks()
        path = 'C:/fake/CowboyBingus/Helldivers2/AutoChat/tasks.txt'
        before_disk = h.virtual_files[path]
        mod.add_task('Snapshot task', 'repeat', '5', 'from preset', 1100, 'host')
        saved = library.save('snapshot', 'host')
        self.assertTrue(saved[0], saved[1])
        self.assertTrue(mod.remove_task(mod.tasks[2].id))
        self.assertTrue(mod.debug_restore_tasks(before_memory))

        h.deny_settings_write = True
        result = library.apply(saved[2], 'host')

        self.assertFalse(result[0])
        self.assertIn('设置保存失败', result[1])
        self.assertEqual(before_memory, mod.debug_serialize_tasks())
        self.assertEqual(before_disk, h.virtual_files[path])
        self.assertEqual(existing.id, mod.tasks[1].id)

    def test_selected_preset_id_persists_independently_for_both_roles(self):
        lua, h, mod = self.fresh()
        panel = mod.debug_panel()
        panel.preset_selected_by_role['host'] = 'P00000011'
        panel.preset_selected_by_role['client'] = 'P00000012'
        self.assertTrue(mod.debug_save_preset_selection())
        path = 'C:/fake/CowboyBingus/Helldivers2/AutoChat/preset-selection.txt'
        persisted = h.virtual_files[path]
        self.assertEqual('host=P00000011\nclient=P00000012\n', persisted)

        # A new VM reads the exact persisted bytes, modeling a full restart.
        _, restarted_h = fresh_image()
        restarted_h.virtual_files[path] = persisted
        restarted = restarted_h.load(SOURCE)
        selected = restarted.debug_panel().preset_selected_by_role
        self.assertEqual('P00000011', selected['host'])
        self.assertEqual('P00000012', selected['client'])

    def test_repeat_and_countdown_have_independent_deadlines(self):
        _, h, mod = self.fresh()
        repeat = mod.add_task("Repeat", "repeat", "30", "first", 1000)
        once = mod.add_task("Once", "once", "45", "second", 1000)
        self.assertIsNotNone(repeat)
        self.assertIsNotNone(once)
        mod.debug_run_tasks(1029)
        self.assertEqual(0, h.call_count())
        mod.debug_run_tasks(1030)
        self.assertEqual("\nfirst\0", h.last_call()["arg3_text"])
        mod.debug_run_tasks(1045)
        self.assertEqual("\nsecond\0", h.last_call()["arg3_text"])
        self.assertTrue(once["done"])
        mod.debug_run_tasks(1046)
        self.assertEqual(2, h.call_count())
        mod.debug_run_tasks(1200)  # missed intervals coalesce, never catch-up spam
        self.assertEqual(3, h.call_count())
        self.assertEqual(1230, repeat["due"])

    def test_scheduled_full_player_name_uses_profile_color_switch(self):
        lua, h, mod = self.fresh()
        lua.execute("local identity=...; identity.lookup=function(peer) return {peer_id=peer,name='Alice',short='A1',color='FF81ACFE',color_index=0} end",
                    mod.debug_identity())
        automation = mod.debug_automation()
        self.assertTrue(automation.set("ping_sender_color", True, "host")[0])
        colored = mod.add_task("Colored", "once", "5", "Hi {玩家名}", 1000, "host")
        mod.debug_run_tasks(1005)
        self.assertEqual("\nHi <c=FF81ACFE>[Alice]<c=FFFFFFFF>\0", h.last_call()["arg3_text"])
        self.assertTrue(automation.set("ping_sender_color", False, "host")[0])
        plain = mod.add_task("Plain", "once", "5", "Hi {名字}", 1010, "host")
        mod.debug_run_tasks(1015)
        self.assertEqual("\nHi [Alice]\0", h.last_call()["arg3_text"])
        self.assertTrue(colored["done"] and plain["done"])

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
        tasks_path = 'C:/fake/CowboyBingus/Helldivers2/AutoChat/tasks.txt'
        self.assertIn("AutoChatTasks1", h.virtual_files[tasks_path])
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
        result=mod.debug_restore_tasks("AutoChatTasks1\nbroken\n")
        self.assertFalse(result[0] if isinstance(result,tuple) else result)
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

    def test_old_enabled_timer_migrates_to_a_host_repeat_task(self):
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
        self.assertEqual(1, len(mod.tasks), "legacy quick timer becomes one visible scheduled task")
        task=mod.tasks[1]
        self.assertEqual('host',task.profile)
        self.assertEqual('repeat',task.mode)
        self.assertEqual(45,task.seconds)
        self.assertEqual('old message',task.message)
        self.assertFalse(mod.debug_automation().profile('host').quick_timer_enabled)
        self.assertFalse(mod.debug_automation().profile('client').quick_timer_enabled)

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
                if tostring(path):find('settings.txt',1,true) then return nil end
                return old(path, mode)
            end
        """)
        mod = h.load(SOURCE)
        written = h.written()
        panel_writes = [written[i]["text"] for i in range(1, len(written) + 1)
                        if "panel.txt" in written[i]["path"]]
        self.assertEqual([], panel_writes, "migration failure must retain the old configuration")
        self.assertTrue(mod.debug_cfg()["timer_on"], "failed migration retains source config for retry")
        before = h.call_count()
        mod.debug_timed_send(3600)
        self.assertEqual(before, h.call_count(), "retired legacy timer stays inert after migration failure")


if __name__ == "__main__":
    unittest.main()
