"""Regressions for real panel mouse actions and scheduled sends in a solo ship."""
import unittest
from test_auto_chat_probe import fresh_image, SOURCE


class PanelInteractionTest(unittest.TestCase):
    def test_panel_text_keeps_readable_pixels_when_labels_are_long(self):
        for rw,rh,minimum in ((1920,1080,14),(2560,1600,21)):
            lua,h=fresh_image(font_ids=True)
            h.res_w,h.res_h=rw,rh
            mod=h.load(SOURCE);mod.debug_set_open(True)
            lua.execute('''drawn={}
                stingray.Gui.text=function(gui,value,font,size,material,pos,colour)
                    drawn[#drawn+1]={value=value,size=size}
                end
                stingray.Gui.text_extents=function(gui,value,font,size)
                    local width=0
                    for ch in tostring(value):gmatch('[%z\\1-\\127\\194-\\244][\\128-\\191]*') do
                        width=width+(#ch>1 and size or size*.6)
                    end
                    return {x=0},{x=width}
                end''')
            lua.execute('for i=1,601 do update() end')
            for view in ('tasks','automation','pings'):
                mod.debug_panel()['settings_view']=view
                lua.execute('drawn={}; for i=1,3 do update() end')
                drawn=lua.globals().drawn
                self.assertGreater(len(drawn),0)
                self.assertGreaterEqual(min(drawn[i]['size'] for i in range(1,len(drawn)+1)),minimum,view)

    def fresh(self):
        lua, h = fresh_image()
        mod = h.load(SOURCE)
        mod.debug_set_open(True)
        lua.execute('for i=1,601 do update() end')
        for field, value in (('name', 'Mouse task'), ('message', 'Mouse message')):
            p = mod.debug_panel()
            p['edit_field'], p['editing'], p['edit_text'] = field, True, value
            h.user32.set_key(0x0D, True)
            lua.eval('update()')
            h.user32.set_key(0x0D, False)
            lua.eval('update()')
        return lua, h, mod

    def point(self, h, mod, key):
        boxes = mod.debug_panel()['regions']
        r = next(boxes[i] for i in range(1, len(boxes)+1) if boxes[i]['key'] == key)
        h.mouse_x = r['x'] + r['w']/2
        h.mouse_y = 1080 - r['y'] - r['h']/2

    def test_drag_moves_the_drawn_panel_and_its_hit_regions(self):
        lua, h, mod = self.fresh()
        self.point(h, mod, 'drag')
        before = mod.debug_geometry(1920, 1080)
        h.user32.set_key(1, True)
        lua.eval('update()')
        h.mouse_x += 200
        h.mouse_y += 80
        lua.eval('update()')
        h.user32.set_key(1, False)
        lua.eval('update()')
        after = mod.debug_geometry(1920, 1080)
        self.assertEqual(before['x']+200, after['x'])
        self.assertEqual(before['y']+80, after['y'])
        self.assertIsNone(mod.debug_panel()['drag'])
        self.point(h, mod, 'task:add')
        h.user32.set_key(1, True)
        lua.eval('update()')
        h.user32.set_key(1, False)
        lua.eval('update()')
        self.assertEqual(1, len(mod.tasks), 'moved controls still respond')
        written = h.written()
        self.assertTrue(any('panel-position.txt' in written[i]['path'] for i in range(1, len(written)+1)))

    def test_armory_click_activates_only_on_release_inside_same_button(self):
        lua, h, mod = self.fresh()
        self.point(h, mod, 'task:add')
        h.user32.set_key(1, True)
        lua.eval('update()')
        self.assertEqual(0, len(mod.tasks), 'press arms a button; release activates it')
        h.mouse_x, h.mouse_y = 1800, 1000
        h.user32.set_key(1, False)
        lua.eval('update()')
        self.assertEqual(0, len(mod.tasks), 'releasing elsewhere cancels the action')

    def test_saved_position_is_clamped_and_scales_with_resolution(self):
        lua, h = fresh_image()
        lua.execute('''local old=io.open
            io.open=function(path,mode)
                if tostring(path):find('panel-position.txt',1,true) and mode=='r' then
                    return {read=function() return 'x = 0.25\\ny = 0.1\\n' end,close=function() end}
                end
                return old(path,mode)
            end''')
        mod = h.load(SOURCE)
        geo = mod.debug_geometry(1920, 1080)
        self.assertEqual(480, geo['x'])
        self.assertEqual(108, geo['y'])
        geo = mod.debug_geometry(1280, 720)
        self.assertEqual(320, geo['x'])
        self.assertEqual(72, geo['y'])
        mod.debug_panel()['pos'] = lua.table_from({'fx': 2, 'fy': -3})
        geo = mod.debug_geometry(1280, 720)
        self.assertLessEqual(geo['x']+geo['w'], 1280)
        self.assertGreaterEqual(geo['y'], 0)

    def test_ctrl_zero_resets_dragged_position(self):
        lua, h, mod = self.fresh()
        mod.debug_panel()['pos'] = lua.table_from({'fx': .2, 'fy': .1})
        h.user32.set_key(0x11, True)
        h.user32.set_key(0x30, True)
        lua.eval('update()')
        self.assertIsNone(mod.debug_panel()['pos'])
        self.assertEqual(24, mod.debug_geometry(1920, 1080)['x'])

    def test_automation_settings_buttons_and_custom_fields_are_connected(self):
        lua, h, mod = self.fresh()
        def click(key):
            self.point(h, mod, key)
            h.user32.set_key(1, True)
            lua.eval('update()')
            h.user32.set_key(1, False)
            lua.eval('update()')
        click('view:automation')
        boxes = mod.debug_panel()['regions']
        keys = {boxes[i]['key'] for i in range(1, len(boxes)+1)}
        self.assertTrue({'opt:enabled', 'opt:allow_solo', 'opt:welcome',
            'scope:host', 'scope:all', 'option:welcome_message',
            'option:cooldown', 'option:welcome_delay'} <= keys)
        self.assertTrue(mod.options['allow_solo'])
        click('opt:allow_solo')
        self.assertFalse(mod.options['allow_solo'])
        click('scope:host')
        self.assertEqual('host', mod.options['scope'])
        click('option:welcome_message')
        mod.debug_set_edit_buffer('你好，欢迎！')
        h.user32.set_key(0x0D, True)
        lua.eval('update()')
        h.user32.set_key(0x0D, False)
        lua.eval('update()')
        self.assertEqual('你好，欢迎！', mod.options['welcome_message'])
        self.assertTrue(any('settings.txt' in h.written()[i]['path'] for i in range(1,len(h.written())+1)))
        click('view:tasks')
        self.point(h, mod, 'task:add')

    def test_zoom_key_can_be_released_when_ctrl_is_not_held(self):
        lua, h, mod = self.fresh()
        for expected in (1.1, 1.2):
            h.user32.set_key(0x11, True)
            h.user32.set_key(0xBB, True)
            lua.eval('update()')
            self.assertAlmostEqual(expected, mod.debug_panel()['ui_scale'])
            h.user32.set_key(0x11, False)
            h.user32.set_key(0xBB, False)
            lua.eval('update()')

    def test_ping_page_has_building_stratagem_map_and_enemy_switches(self):
        lua, h, mod = self.fresh()
        def click(key):
            self.point(h, mod, key)
            h.user32.set_key(1, True); lua.eval('update()')
            h.user32.set_key(1, False); lua.eval('update()')
        click('view:pings')
        for option in ('ping_building','ping_stratagem','ping_summon','ping_map','ping_medium_enemy','ping_large_enemy','ping_giant_enemy','ping_sender_prefix','ping_sender_color'):
            self.assertTrue(mod.options[option])
            click('opt:'+option)
            self.assertFalse(mod.options[option])
        self.point(h, mod, 'opt:ping')
        self.point(h, mod, 'option:ping_message')
        click('option:summon_message')
        mod.debug_set_edit_buffer('{缩写}{动作}了{目标}')
        h.user32.set_key(0x0D, True); lua.eval('update()')
        h.user32.set_key(0x0D, False); lua.eval('update()')
        self.assertEqual('{缩写}{动作}了{目标}', mod.options['summon_message'])
        self.assertTrue(any('settings.txt' in h.written()[i]['path'] for i in range(1,len(h.written())+1)))

    def test_all_settings_pages_have_visible_nonoverlapping_hit_regions(self):
        for rw, rh in ((1280,720), (1920,1080), (3840,2160)):
            lua, h = fresh_image()
            h.res_w, h.res_h = rw, rh
            mod = h.load(SOURCE)
            mod.debug_set_open(True)
            for view in ('tasks','automation','pings'):
                mod.debug_panel()['settings_view'] = view
                lua.execute('for i=1,601 do update() end')
                geo = mod.debug_geometry(rw, rh)
                regions = mod.debug_panel()['regions']
                boxes = [regions[i] for i in range(1,len(regions)+1)]
                for a in boxes:
                    self.assertGreaterEqual(a['y'], rh-geo['y']-geo['h']-1)
                    self.assertLessEqual(a['y']+a['h'], rh-geo['y']+1)
                    self.assertGreaterEqual(a['x'], geo['x']-1)
                    self.assertLessEqual(a['x']+a['w'], geo['x']+geo['w']+1)
                for i,a in enumerate(boxes):
                    for b in boxes[i+1:]:
                        dx = min(a['x']+a['w'],b['x']+b['w'])-max(a['x'],b['x'])
                        dy = min(a['y']+a['h'],b['y']+b['h'])-max(a['y'],b['y'])
                        self.assertFalse(dx>1 and dy>1, (view,a['key'],b['key']))


class ScheduledAvailabilityTest(unittest.TestCase):
    def test_short_repeat_cannot_starve_a_countdown_during_global_cooldown(self):
        _, h = fresh_image()
        mod = h.load(SOURCE)
        mod.add_task('Repeat', 'repeat', '5', 'repeat', 1000)
        once = mod.add_task('Once', 'once', '5', 'once', 1000)
        for now in (1005, 1010, 1015):
            mod.debug_run_tasks(now)
        self.assertTrue(once['done'], 'oldest overdue task must get the next slot')
        self.assertEqual(3, h.call_count())

    def test_peer_guard_uses_slots_even_when_raw_count_is_zero(self):
        _, h = fresh_image(others=2)
        mod = h.load(SOURCE)
        h.u32(h.ctx_base+mod.PEER_COUNT, 0)
        ok, count = mod.send_text('real peers', False)
        self.assertTrue(ok)
        self.assertEqual(2, count)

    def test_solo_schedule_reaches_the_native_chat_sender(self):
        _, h = fresh_image(others=0)
        mod = h.load(SOURCE)
        task = mod.add_task('Solo', 'once', '5', 'hello solo', 1000)
        mod.debug_run_tasks(1005)
        self.assertEqual(1, h.call_count(), 'solo is a valid chat session')
        self.assertEqual('hello solo\0', h.last_call()['arg3_text'])
        self.assertTrue(task['done'])

    def test_unavailable_chat_does_not_consume_countdown_and_retries_later(self):
        _, h = fresh_image(chat_flag=0)
        mod = h.load(SOURCE)
        task = mod.add_task('Wait', 'once', '5', 'send after ready', 1000)
        mod.debug_run_tasks(1005)
        self.assertFalse(task['done'], 'a disabled chat is not a completed send')
        self.assertTrue(task['enabled'])
        self.assertEqual(0, h.call_count())
        self.assertIn('等待', task['result'])
        h.bytes(h.ctx_base+mod.CHAT_OBJECT, chr(1))
        mod.debug_run_tasks(1006)
        self.assertEqual(0, h.call_count(), 'retry backoff is respected')
        mod.debug_run_tasks(1010)
        self.assertEqual(1, h.call_count())
        self.assertTrue(task['done'])


if __name__ == '__main__':
    unittest.main()
