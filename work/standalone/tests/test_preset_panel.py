"""Retained panel interactions for named automation presets."""
import unittest
from test_auto_chat_probe import fresh_image, SOURCE


class PresetPanelTests(unittest.TestCase):
    def fresh(self):
        lua, h = fresh_image(font_ids=True)
        mod = h.load(SOURCE)
        mod.debug_set_open(True)
        lua.execute('for i=1,601 do update() end')
        return lua, h, mod

    def click(self, lua, h, mod, key):
        regions = mod.debug_panel().regions
        region = next(regions[i] for i in range(1, len(regions)+1)
                      if regions[i].key == key)
        h.mouse_x, h.mouse_y = region.x + region.w/2, 1080 - region.y - region.h/2
        h.user32.set_key(1, True)
        lua.eval('update()')
        h.user32.set_key(1, False)
        lua.eval('update()')

    def enter(self, lua, h, mod, value):
        mod.debug_set_edit_buffer(value)
        h.user32.set_key(0x0D, True)
        lua.eval('update()')
        h.user32.set_key(0x0D, False)
        lua.eval('update()')

    def test_open_save_apply_export_delete_and_import_through_panel(self):
        lua, h, mod = self.fresh()
        self.click(lua, h, mod, 'presets:open')
        self.assertTrue(mod.debug_panel().preset_view)
        self.click(lua, h, mod, 'preset:name')
        self.enter(lua, h, mod, '小队欢迎')
        self.click(lua, h, mod, 'preset:save')
        self.assertEqual('P00000001', mod.debug_panel().preset_selected_by_role['host'])
        self.click(lua, h, mod, 'preset:name')
        self.enter(lua, h, mod, '小队欢迎-主机')
        self.click(lua, h, mod, 'preset:rename')
        self.assertEqual('小队欢迎-主机', mod.debug_preset_library().list('host')[1].name)

        automation = mod.debug_automation()
        automation.set('welcome_message', 'changed after capture', 'host')
        self.click(lua, h, mod, 'preset:apply')
        self.assertEqual('欢迎加入小队！', automation.profile('host').welcome_message)
        automation.set('welcome_message', 'replacement value', 'host')
        self.click(lua, h, mod, 'preset:replace')
        automation.set('welcome_message', 'changed after replacement', 'host')
        self.click(lua, h, mod, 'preset:apply')
        self.assertEqual('replacement value', automation.profile('host').welcome_message)
        self.click(lua, h, mod, 'preset:export')
        writes = h.written()
        export = next(writes[i] for i in range(1, len(writes)+1)
                      if 'exports/preset-P00000001.autochat' in writes[i].path)
        self.assertIn('# AutoChat preset v1', export.text)
        self.click(lua, h, mod, 'preset:delete')

        lua.globals().exported_preset = export.text
        lua.execute('''local old=io.open
            io.open=function(path,mode)
                if path=='C:/fixtures/import.autochat' then
                    return {read=function(self,n)return exported_preset:sub(1,n)end,close=function()return true end}
                end
                return old(path,mode)
            end''')
        self.click(lua, h, mod, 'preset:path')
        self.enter(lua, h, mod, 'C:/fixtures/import.autochat')
        self.click(lua, h, mod, 'preset:import')
        self.assertEqual('P00000002', mod.debug_panel().preset_selected_by_role['host'])
        self.assertEqual('小队欢迎-主机', mod.debug_preset_library().list('host')[1].name)

    def test_profile_targets_stay_separate_and_failed_save_does_not_add_entry(self):
        lua, h, mod = self.fresh()
        self.click(lua, h, mod, 'presets:open')
        p = mod.debug_panel()
        p.preset_name = 'Host profile'
        self.click(lua, h, mod, 'preset:save')
        automation = mod.debug_automation()
        host_message = automation.profile('host').welcome_message
        self.click(lua, h, mod, 'profile:client')
        automation.set('welcome_message', 'client only', 'client')
        p.preset_name = 'Client profile'
        self.click(lua, h, mod, 'preset:save')
        client_id = p.preset_selected_by_role['client']
        self.assertIsNotNone(client_id)
        self.assertNotEqual(p.preset_selected_by_role['host'], client_id)
        automation.set('welcome_message', 'mutated client', 'client')
        self.click(lua, h, mod, 'preset:apply')
        self.assertEqual('client only', automation.profile('client').welcome_message)
        self.assertEqual(host_message, automation.profile('host').welcome_message)

        lua.execute('''local old=io.open
            io.open=function(path,mode)
                if tostring(path):find('presets.txt.tmp',1,true) then return nil,'disk full' end
                return old(path,mode)
            end''')
        p.preset_name = 'Must not be added'
        before = len(mod.debug_preset_library().list('host'))
        self.click(lua, h, mod, 'preset:save')
        self.assertEqual(before, len(mod.debug_preset_library().list('host')))
        self.assertIn('预设文件', p.hint)

    def test_apply_names_the_destination_and_warns_when_active_role_differs(self):
        lua,h,mod=self.fresh();self.click(lua,h,mod,'presets:open')
        p=mod.debug_panel();a=mod.debug_automation()
        p.profile='host'
        lua.execute("stingray.GameSession.game_session_host=function() return tostring(0x00112233445567) end")
        a.sync()
        self.assertEqual('client',a.state.active_role)
        mod.debug_language().update('zh',1)
        p.preset_name='Host profile';self.click(lua,h,mod,'preset:save')
        preset_id=p.preset_selected_by_role['host']
        a.set('welcome_message','mutated host','host')
        a.set('welcome_message','client stays','client')
        self.click(lua,h,mod,'preset:apply')
        self.assertEqual('欢迎加入小队！',a.profile('host').welcome_message)
        self.assertEqual('client stays',a.profile('client').welcome_message)
        self.assertIn('主机',p.hint)
        self.assertIn('客机',p.hint)

    def test_apply_does_not_claim_match_when_role_sync_is_unknown(self):
        lua,h,mod=self.fresh();self.click(lua,h,mod,'presets:open')
        p=mod.debug_panel();a=mod.debug_automation()
        p.profile='host';p.preset_name='Host profile'
        self.click(lua,h,mod,'preset:save')
        # The automation constructor's cached value is host, but no session host
        # is available now. Applying a host preset must not treat that cache as proof.
        a.state.active_role='host'
        lua.execute("stingray.GameSession.game_session_host=function() return nil end")
        self.assertIsNone(a.sync())
        self.click(lua,h,mod,'preset:apply')
        self.assertIn('session role is not confirmed',p.hint)
        self.assertNotIn('active role matches',p.hint)

    def test_preset_page_regions_fit_and_all_32_entries_are_paginated(self):
        lua, h, mod = self.fresh()
        library = mod.debug_preset_library()
        for i in range(32):
            ok, _, _ = library.save('Preset %02d' % i, 'host')
            self.assertTrue(ok)
        mod.debug_panel().preset_view = True
        lua.execute('for i=1,3 do update() end')
        geo = mod.debug_geometry(1920, 1080)
        boxes = mod.debug_panel().regions
        regions = [boxes[i] for i in range(1, len(boxes)+1)]
        for box in regions:
            self.assertGreaterEqual(box.x, geo.x-1)
            self.assertLessEqual(box.x+box.w, geo.x+geo.w+1)
            self.assertGreaterEqual(box.y, 1080-geo.y-geo.h-1)
            self.assertLessEqual(box.y+box.h, 1080-geo.y+1)
        for i, a in enumerate(regions):
            for b in regions[i+1:]:
                dx = min(a.x+a.w,b.x+b.w)-max(a.x,b.x)
                dy = min(a.y+a.h,b.y+b.h)-max(a.y,b.y)
                self.assertFalse(dx > 1 and dy > 1, (a.key,b.key))
        self.assertTrue(any(r.key == 'preset:select:P00000016' for r in regions))
        self.click(lua, h, mod, 'preset:next')
        lua.execute('for i=1,3 do update() end')
        self.assertEqual(2, mod.debug_panel().preset_page_by_role['host'])
        boxes = mod.debug_panel().regions
        self.assertTrue(any(boxes[i].key == 'preset:select:P00000032'
                            for i in range(1,len(boxes)+1)))

    def test_native_ring_text_is_drained_before_save_click(self):
        lua, h, mod = self.fresh()
        self.click(lua, h, mod, 'presets:open')
        p = mod.debug_panel()
        p.preset_name = ''
        p.editing, p.edit_field, p.edit_text = True, 'preset:name', ''
        p.input_edit_field = 'preset:name'
        panel_input = mod.debug_panel_input()
        lua.execute("""queued = true
            local input = ...
            local old_status = input.status
            input.status = function() local value=old_status();value.broken=false;return value end
            input.drain = function()
                if queued then queued=false; return {{message=0x0102,wparam=0x58,lparam=1}}, false end
                return {}, false
            end""", panel_input)
        lua.eval('update()')
        self.assertEqual('X', p.edit_text,
                         'queued native text must be consumed before the next interaction')
        self.click(lua, h, mod, 'preset:save')
        entries = mod.debug_preset_library().list('host')
        self.assertEqual(1, len(entries), 'the click must save exactly one preset')
        self.assertEqual('X', entries[1].name,
                         'the queued character must reach the edited name before save')

    def test_pending_native_ring_text_survives_focus_release(self):
        lua, h, mod = self.fresh()
        p = mod.debug_panel()
        p.editing, p.edit_field, p.edit_text = True, 'preset:name', ''
        p.input_edit_field = 'preset:name'
        panel_input = mod.debug_panel_input()
        lua.execute("""queued = true
            local input = ...
            local old_status = input.status
            input.status = function() local value=old_status();value.broken=false;return value end
            input.drain = function()
                if queued then queued=false; return {{message=0x0102,wparam=0x59,lparam=1}}, false end
                return {}, false
            end""", panel_input)
        h.own_pid = 31337
        lua.eval('update()')
        self.assertEqual('Y', p.edit_text,
                         'drain happens before focus-loss release, preserving the final character')
        self.assertTrue(p.editing, 'focus loss keeps the current field draft available for resume or explicit cancel')

    def test_missing_library_is_empty_and_can_be_saved(self):
        lua, h = fresh_image(font_ids=True)
        mod = h.load(SOURCE)
        library = mod.debug_preset_library()
        self.assertIsNone(library.state.error)
        ok, _, preset_id = library.save('First preset', 'host')
        self.assertTrue(ok)
        self.assertEqual('P00000001', preset_id)
        self.assertTrue(any('presets.txt.tmp' in h.written()[i].path
                            for i in range(1, len(h.written())+1)))

    def test_permission_read_and_close_failures_lock_out_writes(self):
        for mode, expected in (('permission', '无法读取预设文件'),
                               ('read', '读取预设文件失败'),
                               ('close', '关闭预设文件失败')):
            with self.subTest(mode=mode):
                lua, h = fresh_image(font_ids=True)
                lua.globals().preset_test_mode = mode
                lua.execute('''local old=io.open
                    io.open=function(path,open_mode)
                        if tostring(path):find('presets.txt',1,true) and open_mode=='rb' then
                            if preset_test_mode=='permission' then
                                return nil,'Permission denied',5
                            end
                            return {
                                read=function(self,n)
                                    if preset_test_mode=='read' then error('read failed') end
                                    return 'not a library'
                                end,
                                close=function(self)
                                    if preset_test_mode=='close' then return nil,'close failed' end
                                    return true
                                end}
                        end
                        return old(path,open_mode)
                    end''')
                mod = h.load(SOURCE)
                library = mod.debug_preset_library()
                self.assertIn(expected, library.state.error)
                ok, why = library.save('Do not overwrite', 'host')
                self.assertFalse(ok)
                self.assertIn('库不可用', why)
                writes = h.written()
                self.assertFalse(any('presets.txt.tmp' in writes[i].path
                                     for i in range(1, len(writes)+1)))

    def test_saved_output_preview_preserves_client_only_until_explicit_apply(self):
        lua, h, mod = self.fresh()
        mod.debug_language().update('zh', 0)
        automation = mod.debug_automation()
        automation.set('output', 'squad', 'host')
        ok, _, host_preset_id = mod.debug_preset_library().save('Public host', 'host')
        self.assertTrue(ok)
        automation.set('output', 'squad', 'client')
        ok, _, preset_id = mod.debug_preset_library().save('Public client', 'client')
        self.assertTrue(ok)
        self.assertNotEqual(host_preset_id, preset_id)
        automation.set('output', 'local', 'client')
        p = mod.debug_panel()
        p.profile, p.preset_view = 'client', True
        p.preset_selected_by_role['client'] = preset_id
        lua.execute('''captured_text={}
            stingray.Gui.text=function(gui,value,...)captured_text[#captured_text+1]=tostring(value)end
            stingray.Gui.text_extents=function(gui,value,face,size)return {x=0},{x=#tostring(value)*size*.5}end''')
        lua.execute('for i=1,3 do update() end')
        labels = [str(lua.globals().captured_text[i])
                  for i in range(1, len(lua.globals().captured_text)+1)]
        self.assertTrue(any('将载入：小队公屏' in s for s in labels), labels)
        self.assertTrue(any('当前配置输出：仅自己可见' in s for s in labels), labels)
        self.assertEqual('local', automation.profile('client').output)
        self.assertEqual('local', automation.profile('client').output)


if __name__ == '__main__':
    unittest.main()
