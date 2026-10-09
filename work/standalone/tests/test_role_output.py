"""Role UI, scheduled routing, and the native local-only boundary."""
import unittest
from test_auto_chat_probe import fresh_image, SOURCE


class RoleOutputTests(unittest.TestCase):
    def fresh(self):
        lua,h=fresh_image(font_ids=True)
        mod=h.load(SOURCE)
        lua.globals().h=h;lua.globals().m=mod
        lua.execute('h.bytes(h.code_base+m.LOCAL_LINE_RVA,m.LOCAL_LINE_BYTES)')
        mod.debug_set_open(True)
        lua.execute('for i=1,601 do update() end')
        return lua,h,mod

    def click(self,lua,h,mod,key):
        regions=mod.debug_panel().regions
        r=next(regions[i] for i in range(1,len(regions)+1) if regions[i].key==key)
        h.mouse_x,h.mouse_y=r.x+r.w/2,1080-r.y-r.h/2
        h.user32.set_key(1,True);lua.eval('update()')
        h.user32.set_key(1,False);lua.eval('update()')

    def test_local_output_calls_only_add_line_with_all_peer_bits(self):
        lua,h,mod=self.fresh()
        lua.globals().h=h;lua.globals().m=mod
        lua.execute("h.bytes(h.ctx_base+m.LOCAL,string.char(254,255,255,255,255,255,255,255))")
        before=h.call_count()
        self.assertEqual((True,'local'),mod.display_local('私有提示'))
        self.assertEqual(before+1,h.call_count())
        self.assertEqual(h.code_base+0x10979c0,h.last_call().address)
        self.assertEqual('FFFFFFFFFFFFFFFE',h.last_call().arg2)
        self.assertEqual('私有提示\0',h.last_call().arg3_text)
        self.assertEqual(0,mod.sent)

    def test_bad_local_signature_fails_without_a_network_call(self):
        lua,h,mod=self.fresh()
        h.bytes(h.code_base+mod.LOCAL_LINE_RVA,'broken signature')
        self.assertFalse(mod.display_local('private')[0])
        self.assertEqual(0,h.call_count())
        task=mod.add_task('private','once','5','pending',1000,'client')
        lua.execute("stingray.GameSession.game_session_host=function() return tostring(0x00112233445567) end")
        mod.debug_run_tasks(1005)
        self.assertFalse(task.done)
        self.assertEqual(0,h.call_count())

    def test_profile_buttons_edit_separately_and_refresh_controls(self):
        lua,h,mod=self.fresh()
        self.click(lua,h,mod,'profile:client')
        self.click(lua,h,mod,'view:automation')
        a=mod.debug_automation()
        self.assertEqual('client',mod.debug_panel().profile)
        self.assertEqual('local',a.profile('client').output)
        signature=mod.debug_panel_signature()
        self.click(lua,h,mod,'output:squad')
        self.assertEqual('squad',a.profile('client').output)
        self.assertEqual('squad',a.options.output)
        self.assertNotEqual(signature,mod.debug_panel_signature())
        self.click(lua,h,mod,'opt:welcome')
        self.assertTrue(a.profile('client').welcome)
        self.assertFalse(a.profile('host').welcome)

    def test_client_tasks_are_private_and_host_tasks_are_not_consumed(self):
        lua,h,mod=self.fresh()
        host=mod.add_task('host','once','5','public',1000,'host')
        client=mod.add_task('client','once','5','private',1000,'client')
        lua.execute("stingray.GameSession.game_session_host=function() return tostring(0x00112233445567) end")
        mod.debug_run_tasks(1005)
        self.assertFalse(host.done)
        self.assertTrue(client.done)
        self.assertEqual(1,h.call_count())
        self.assertEqual(h.code_base+0x10979c0,h.last_call().address)
        self.assertEqual('private\0',h.last_call().arg3_text)
        self.assertIn('仅自己可见',client.result)
        data=mod.debug_serialize_tasks()
        self.assertTrue(mod.debug_restore_tasks(data))
        self.assertEqual('host',mod.tasks[1].profile)
        self.assertEqual('client',mod.tasks[2].profile)

    def test_client_plugin_api_respects_local_output(self):
        lua,h,mod=self.fresh()
        lua.execute("""stingray.GameSession.game_session_host=function() return tostring(0x00112233445567) end
            HD2AutoChatAPI.register{id='private_test',name='Private',draw=function()end}
            assert(HD2AutoChatAPI.send('private_test','interface private'))""")
        self.assertEqual(1,h.call_count())
        self.assertEqual(h.code_base+0x10979c0,h.last_call().address)

    def test_legacy_timer_also_respects_private_output(self):
        lua,h,mod=self.fresh()
        lua.execute("stingray.GameSession.game_session_host=function() return tostring(0x00112233445567) end")
        automation=mod.debug_automation()
        self.assertTrue(automation.set('quick_timer_enabled',True,'client')[0])
        self.assertTrue(automation.set('quick_timer_interval',5,'client')[0])
        self.assertTrue(automation.set('quick_timer_message','legacy private','client')[0])
        self.assertTrue(automation.set('output','local','client')[0])
        mod.debug_timed_send(5)
        self.assertEqual(1,h.call_count())
        self.assertEqual(h.code_base+0x10979c0,h.last_call().address)

    def test_active_host_quick_timer_ignores_client_profile_being_edited(self):
        lua,h,mod=self.fresh()
        automation=mod.debug_automation()
        self.assertTrue(automation.set('quick_timer_enabled',True,'host')[0])
        self.assertTrue(automation.set('quick_timer_interval',5,'host')[0])
        self.assertTrue(automation.set('quick_timer_message','host quick', 'host')[0])
        self.assertTrue(automation.set('quick_timer_enabled',True,'client')[0])
        self.assertTrue(automation.set('quick_timer_interval',5,'client')[0])
        self.assertTrue(automation.set('quick_timer_message','client quick', 'client')[0])
        self.click(lua,h,mod,'profile:client')
        self.assertEqual('client',mod.debug_panel().profile)
        self.assertEqual('host',automation.state.active_role)
        mod.debug_timed_send(5)
        self.assertEqual('host quick\0',h.last_call().arg3_text)

    def test_quick_timer_page_edits_the_selected_role_and_keeps_role_values_separate(self):
        lua,h,mod=self.fresh()
        automation=mod.debug_automation()
        self.click(lua,h,mod,'profile:client')
        self.click(lua,h,mod,'view:quick')
        self.assertIn('opt:quick_timer_enabled',
            {mod.debug_panel().regions[i].key for i in range(1,len(mod.debug_panel().regions)+1)})
        self.click(lua,h,mod,'opt:quick_timer_enabled')
        self.assertTrue(automation.profile('client').quick_timer_enabled)
        self.assertFalse(automation.profile('host').quick_timer_enabled)
        self.click(lua,h,mod,'option:quick_timer_message')
        mod.debug_set_edit_buffer('客机定时')
        h.user32.set_key(0x0D,True);lua.eval('update()');h.user32.set_key(0x0D,False);lua.eval('update()')
        self.assertEqual('客机定时',automation.profile('client').quick_timer_message)
        self.assertEqual('HELLO FROM AUTOCHAT',automation.profile('host').quick_timer_message)

    def test_quick_timer_discards_partial_elapsed_time_when_active_role_changes(self):
        lua,h,mod=self.fresh()
        automation=mod.debug_automation()
        for role,message in (('host','host interval'),('client','client interval')):
            self.assertTrue(automation.set('quick_timer_enabled',True,role)[0])
            self.assertTrue(automation.set('quick_timer_interval',5,role)[0])
            self.assertTrue(automation.set('quick_timer_message',message,role)[0])
        mod.debug_timed_send(4)
        lua.execute("stingray.GameSession.game_session_host=function() return tostring(0x00112233445567) end")
        automation.sync()
        mod.debug_timed_send(1)
        self.assertEqual(0,h.call_count(), 'host elapsed time cannot finish the client timer')
        mod.debug_timed_send(4)
        self.assertEqual('client interval\0',h.last_call().arg3_text)

    def test_client_task_form_creates_a_client_task_and_lists_only_that_role(self):
        lua,h,mod=self.fresh()
        mod.add_task('host','repeat','30','host message',10000000000,'host')
        self.click(lua,h,mod,'profile:client')
        panel=mod.debug_panel()
        for field,value in (('name','client task'),('message','client message')):
            panel.edit_field=field;panel.editing=True;panel.edit_text=value
            h.user32.set_key(0x0D,True);lua.eval('update()')
            h.user32.set_key(0x0D,False);lua.eval('update()')
        self.click(lua,h,mod,'task:add')
        self.assertEqual('client',mod.tasks[2].profile)
        regions=mod.debug_panel().regions
        keys={regions[i].key for i in range(1,len(regions)+1)}
        self.assertIn('delete:2',keys);self.assertNotIn('delete:1',keys)

    def test_local_signature_is_the_verified_capture_prefix(self):
        lua,_,_=self.fresh()
        value=lua.eval("(m.LOCAL_LINE_BYTES:gsub('.',function(c)return string.format('%02x',c:byte())end))")
        self.assertEqual('4057415541564883ec408039004d8be84c8bf2488bf90f84a7020000',value)


if __name__=='__main__': unittest.main()
