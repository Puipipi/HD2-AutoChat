"""Load the independent example addon and interact with the host's actual UI."""
from pathlib import Path
import unittest
from test_auto_chat_probe import fresh_image, SOURCE

DEMO = Path(__file__).resolve().parents[3] / 'src/examples/interface_demo.lua'


class PluginIntegrationTests(unittest.TestCase):
    def test_host_sends_player_templates_with_independent_peer_limits_and_rejects_departed_peer(self):
        lua,h = fresh_image();mod=h.load(SOURCE)
        lua.globals().test_identity=mod.debug_identity()
        lua.globals().test_api=mod.api
        lua.globals().test_peer_a=str(int('0110000100000022',16))
        lua.globals().test_peer_b=str(int('0110000100000023',16))
        lua.execute('''
            test_peers={'76561198000000001',test_peer_a,test_peer_b}
            stingray.Network={game_session=function()return 'room' end,peer_id=function()return test_peers[1] end}
            stingray.GameSession={peers=function()return test_peers end,
                game_session_host=function()return test_peers[1] end}
            test_profiles={
                ['0110000100000022']={peer_id='0110000100000022',name='Alice',short='A2',color_index=1},
                ['0110000100000023']={peer_id='0110000100000023',name='Bob',short='B3',color_index=2}}
            test_identity.lookup=function(peer)return test_profiles[peer] end
            test_api.register{id='aware',name='Aware',draw=function() end}
            assert(test_api.send('aware','{玩家名}/{缩写}/{编号}','0110000100000022'))
            assert(test_api.send('aware','again','0110000100000022')==false)
            assert(test_api.send('aware','{玩家名}/{缩写}/{编号}','0110000100000023'))
        ''')
        self.assertEqual(h.call_count(),2)
        self.assertEqual(h.last_call().arg3_text.rstrip('\0'),'\n[Bob]/B3/3')
        lua.execute('''test_profiles['0110000100000022']=nil;table.remove(test_peers,2)
            assert(test_api.send('aware','departed','0110000100000022')==false)''')
        self.assertEqual(h.call_count(),2)

    def test_revision3_independent_send_and_detached_role_settings_use_host_runtime(self):
        lua, h = fresh_image(); mod = h.load(SOURCE)
        lua.globals().test_api = mod.api
        lua.globals().test_mod = mod
        lua.globals().mod = mod
        lua.globals().test_peer = str(int('0110000100000022',16))
        lua.globals().test_peer_b = str(int('0110000100000023',16))
        lua.execute('''
            test_peers={'76561198000000001',test_peer,test_peer_b}
            stingray.Network={game_session=function()return 'room' end,peer_id=function()return test_peers[1] end}
            stingray.GameSession={peers=function()return test_peers end,
                game_session_host=function()return test_peers[1] end}
            local callback
            test_api.register{id='revision3',name='Revision 3',draw=function() end,
                on_click=function(_,api) callback=api end}
            test_api.click('revision3','capture')
            assert(callback.api_revision==4 and callback.capabilities.independent_send
                and callback.capabilities.plugin_presets)
            local a=test_api.settings('revision3')
            assert(a.role=='host' and a.output=='squad' and a.rules and a.tasks)
            a.rules.enemy_large_enemy={enabled=true};a.tasks[1]={message='mutated'}
            assert(test_api.settings('revision3').rules.enemy_large_enemy==nil)
            assert(test_api.settings('revision3').tasks[1]==nil)
            assert(callback.send('inherit success','0110000100000022'))
            assert(callback.send('inherit cooldown','0110000100000022')==false)
            assert(test_mod.debug_automation().set('enabled',false))
            assert(callback.send('inherit master-off','0110000100000023')==false)
            assert(test_api.settings('revision3').enabled==false)
            assert(callback.send('independent despite master-off','0110000100000022',{
                policy='independent',cooldown=10,cooldown_key='plugin-alert',output='public'}))
            assert(callback.send('same bucket','0110000100000022',{
                policy='independent',cooldown=10,cooldown_key='plugin-alert',output='public'})==false)
            assert(callback.send('different key','0110000100000022',{
                policy='independent',cooldown=10,cooldown_key='plugin-alert-2',output='public'}))
            assert(callback.send('different creator','0110000100000023',{
                policy='independent',cooldown=10,cooldown_key='plugin-alert',output='public'}))
            assert(callback.send('{player_name} alias',nil,{policy='independent',cooldown=10,
                cooldown_key='self-alias',output='public'}))
            assert(callback.send('same self bucket','0110000100000001',{policy='independent',
                cooldown=10,cooldown_key='self-alias',output='public'})==false)
            test_local_calls=0
            mod.display_local=function() test_local_calls=test_local_calls+1;return false,'local unavailable' end
            assert(callback.send('local has no fallback','0110000100000022',{
                policy='independent',cooldown=10,cooldown_key='local-only',output='local'})==false)
            assert(test_local_calls==1)
            stingray.GameSession.game_session_host=function()return test_peer end
            test_api.click('revision3','capture')
            local client=callback.settings()
            assert(client.role=='client' and client.output=='local')
            test_api.unregister('revision3')
        ''')
        self.assertEqual(h.call_count(), 5,
                         'only inherited and independent public sends should reach native squad send')
        self.assertEqual(h.last_call().arg3_text.rstrip('\0'), '\nTeammate alias')

    def test_plugin_tab_draw_context_and_settings_follow_detected_locale(self):
        lua, h = fresh_image(); mod = h.load(SOURCE)
        lua.globals().mod = mod
        lua.execute('''
            test_texts={}; test_locale='en'; test_plugin_context={}
            local original_text=stingray.Gui.text
            stingray.Gui.text=function(gui,value,...)
                test_texts[#test_texts+1]=tostring(value)
                return original_text(gui,value,...)
            end
            local language=mod.debug_language(); local original_update=language.update
            language.update=function(option,frame)
                if option=='auto' then return original_update(test_locale,frame) end
                return original_update(option,frame)
            end
            assert(mod.register_plugin({id='localeprobe',name='中文插件',name_en='English Plugin',
                draw=function(u,ctx,api)
                    local settings=api.settings()
                    test_plugin_context={context=ctx.language,facade=u.language,
                        settings=settings and settings.language}
                end}))
            mod.debug_set_open(true)
            for i=1,601 do update() end
        ''')
        self.click(lua, h, mod, 'tab:localeprobe')
        en_texts = lua.globals().test_texts
        self.assertTrue(any(en_texts[i].upper() == 'ENGLISH PLUGIN'
                            for i in range(1, len(en_texts)+1)))
        ctx = lua.globals().test_plugin_context
        self.assertEqual((ctx.context, ctx.facade, ctx.settings), ('en', 'en', 'en'))
        drag = next(mod.debug_panel().regions[i] for i in range(1, len(mod.debug_panel().regions)+1)
                    if mod.debug_panel().regions[i].key == 'drag')
        h.mouse_x, h.mouse_y = drag.x + drag.w/2, 1080 - drag.y - drag.h/2
        # The retained GUI is rebuilt only when its signature changes. Force that
        # redraw after placing the synthetic cursor in the drag region so the test
        # captures the localized title-bar branch itself.
        lua.execute('mod.debug_panel().sig=nil; test_texts={}; update()')
        self.assertEqual(mod.debug_panel().hover, 'drag')
        self.assertIn('Drag to move / Ctrl+0 to reset',
                      [lua.globals().test_texts[i] for i in range(1, len(lua.globals().test_texts)+1)])
        lua.execute('test_texts={}; test_locale="zh"; update()')
        zh_texts = lua.globals().test_texts
        self.assertTrue(any(zh_texts[i] == '中文插件'
                            for i in range(1, len(zh_texts)+1)))
        ctx = lua.globals().test_plugin_context
        self.assertEqual((ctx.context, ctx.facade, ctx.settings), ('zh', 'zh', 'zh'))
        drag = next(mod.debug_panel().regions[i] for i in range(1, len(mod.debug_panel().regions)+1)
                    if mod.debug_panel().regions[i].key == 'drag')
        h.mouse_x, h.mouse_y = drag.x + drag.w/2, 1080 - drag.y - drag.h/2
        lua.execute('mod.debug_panel().sig=nil; test_texts={}; update()')
        self.assertIn('拖动移动窗口 / Ctrl+0 复位',
                      [lua.globals().test_texts[i] for i in range(1, len(lua.globals().test_texts)+1)])

    def click(self, lua, h, mod, key):
        regions = mod.debug_panel().regions
        region = next(regions[i] for i in range(1, len(regions)+1) if regions[i].key == key)
        h.mouse_x, h.mouse_y = region.x + region.w/2, 1080 - region.y - region.h/2
        h.user32.set_key(1, True); lua.eval('update()')
        h.user32.set_key(1, False); lua.eval('update()')

    def test_example_registers_before_host_and_clicks_through_public_send_policy(self):
        lua, h = fresh_image()
        lua.execute(DEMO.read_text(encoding='utf-8'))
        mod = h.load(SOURCE)
        self.assertIsNotNone(mod.PLUGIN_BY_ID.auto_chat_demo)
        self.assertEqual(mod.PLUGIN_BY_ID.auto_chat_demo.title, '接口示例')
        mod.debug_set_open(True)
        lua.execute('for i=1,601 do update() end')
        regions = mod.debug_panel().regions
        tabs = {regions[i].key: regions[i] for i in range(1, len(regions)+1)
                if regions[i].key.startswith('tab:')}
        self.assertIn('tab:default', tabs)
        self.assertIn('tab:auto_chat_demo', tabs)
        self.assertLess(tabs['tab:default'].x, tabs['tab:auto_chat_demo'].x,
                        'the independently registered plugin must appear beside SETTINGS')
        self.click(lua, h, mod, 'tab:auto_chat_demo')
        self.assertEqual(mod.debug_panel().active_plugin, 'auto_chat_demo')
        self.assertIsNone(mod.PLUGIN_BY_ID.auto_chat_demo._on_event,
                          'the message example must not subscribe to live event sampling')
        self.assertFalse(mod.api.has_listeners())
        self.assertEqual(h.call_count(), 0)
        self.click(lua, h, mod, 'plugin:auto_chat_demo:template')
        self.assertEqual(h.call_count(), 0, 'editing plugin-owned message data must not send')
        self.assertTrue(mod.debug_automation().set('cooldown', 0)[0])
        self.click(lua, h, mod, 'plugin:auto_chat_demo:send')
        self.assertEqual(h.call_count(), 1)
        self.assertEqual(h.last_call().arg3_text.rstrip('\0'),
                     '\nAutoChat API demo: custom message Beta',
                         'the plugin-generated string must pass through AutoChat send')
        self.click(lua, h, mod, 'plugin:auto_chat_demo:sample')
        self.assertEqual(h.call_count(), 2,
                         'the demo’s own sample handler may send only through callback api.send')
        self.assertEqual(h.last_call().arg3_text.rstrip('\0'),
                         '\nAutoChat API demo: local sample event #1 (Map marker)')
        self.assertTrue(mod.debug_automation().set('enabled', False)[0])
        self.click(lua, h, mod, 'plugin:auto_chat_demo:send')
        self.assertEqual(h.call_count(), 2, 'master switch applies to registered addons')
        self.click(lua, h, mod, 'plugin:auto_chat_demo:mode')
        self.click(lua, h, mod, 'plugin:auto_chat_demo:send')
        self.assertEqual(h.call_count(), 3,
                         'the demo explicitly switches to independent policy while master is off')
        self.click(lua, h, mod, 'plugin:auto_chat_demo:send')
        self.assertEqual(h.call_count(), 4, 'zero independent cooldown permits immediate repeats')
        self.click(lua, h, mod, 'plugin:auto_chat_demo:cooldown')
        self.click(lua, h, mod, 'plugin:auto_chat_demo:send')
        self.assertEqual(h.call_count(), 5, 'first send after enabling a 5-second bucket succeeds')
        self.click(lua, h, mod, 'plugin:auto_chat_demo:send')
        self.assertEqual(h.call_count(), 5, 'the same plugin bucket is refused inside cooldown')
        self.click(lua, h, mod, 'plugin:auto_chat_demo:enabled')
        current_regions = mod.debug_panel().regions
        current_keys = {current_regions[i].key for i in range(1, len(current_regions)+1)}
        self.assertNotIn('plugin:auto_chat_demo:send', current_keys,
                         'disabled mode removes the visible send control')
        self.assertFalse(mod.api.click('auto_chat_demo', 'send')[0])
        self.assertEqual(h.call_count(), 5, 'disabled independent sending never reaches the host')

    def test_late_loading_and_paged_tabs_make_every_registered_name_accessible(self):
        lua, h = fresh_image()
        mod = h.load(SOURCE)
        lua.execute(DEMO.read_text(encoding='utf-8'))
        lua.execute('''for i=1,15 do HD2AutoChatPlugins.register({id='p'..i,
            name='Long registered mod name '..i,draw=function() end}) end''')
        mod.debug_set_open(True); lua.execute('for i=1,601 do update() end')
        seen = set()
        for _ in range(20):
            regions = mod.debug_panel().regions
            keys = {regions[i].key for i in range(1,len(regions)+1)}
            seen.update(key for key in keys if key.startswith('tab:'))
            if 'tabs:next' not in keys:
                break
            self.click(lua, h, mod, 'tabs:next')
        self.assertEqual(len(seen), 17, 'settings and all 16 addon menus must be reachable')

    def test_plugin_context_has_bounded_body_and_only_loaded_catalog_icon(self):
        lua, h = fresh_image(); h.can_get = True
        mod = h.load(SOURCE)
        lua.globals().test_mod = mod
        lua.execute('''
            stingray.Gui.bitmap_uv=function(...)
                test_bitmap_draws=(test_bitmap_draws or 0)+1;return true
            end
            test_mod.register_plugin{id='ctxprobe',name='Context Probe',draw=function(u,ctx)
                test_plugin_context=ctx
                if ctx.loaded_icon then assert(u.icon(ctx.loaded_icon,10,10,24)) end
            end}
        ''')
        mod.debug_set_open(True); lua.execute('for i=1,601 do update() end')
        self.click(lua, h, mod, 'tab:ctxprobe')
        self.assertGreater(lua.eval('test_plugin_context.content_w'), 0)
        self.assertGreater(lua.eval('test_plugin_context.content_h'), 0)
        self.assertIsNone(lua.eval('test_plugin_context.loaded_icon'),
                          'an empty native catalog must not invent an icon id')
        self.assertIsNotNone(mod.PLUGIN_BY_ID.ctxprobe,
                             'missing optional icon must not unregister a valid plugin')
        lua.execute('''
            local catalog=test_mod.debug_stratagem_catalog()
            catalog.state.entries={{icon='0123456789ABCDEF'}}
            catalog.state.generation=catalog.state.generation+1
            update()
        ''')
        self.assertEqual(lua.eval('test_plugin_context.loaded_icon'), '0123456789ABCDEF')
        self.assertGreater(lua.eval('test_bitmap_draws or 0'), 0,
                           'a verified loaded material must use the host draw closure')
        self.assertIsNotNone(mod.PLUGIN_BY_ID.ctxprobe)


if __name__ == '__main__':
    unittest.main()
