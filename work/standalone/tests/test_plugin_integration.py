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
            stingray.GameSession={peers=function()return test_peers end}
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
        self.assertEqual(h.last_call().arg3_text.rstrip('\0'),'Bob/B3/3')
        lua.execute('''test_profiles['0110000100000022']=nil;table.remove(test_peers,2)
            assert(test_api.send('aware','departed','0110000100000022')==false)''')
        self.assertEqual(h.call_count(),2)

    def click(self, lua, h, mod, key):
        regions = mod.debug_panel().regions
        region = next(regions[i] for i in range(1, len(regions)+1) if regions[i].key == key)
        h.mouse_x, h.mouse_y = region.x + region.w/2, 1080 - region.y - region.h/2
        h.user32.set_key(1, True); lua.eval('update()')
        h.user32.set_key(1, False); lua.eval('update()')

    def test_example_registers_before_host_then_clicks_toggle_and_sends_through_policy(self):
        lua, h = fresh_image()
        lua.execute(DEMO.read_text(encoding='utf-8'))
        mod = h.load(SOURCE)
        self.assertIsNotNone(mod.PLUGIN_BY_ID.auto_chat_demo)
        self.assertEqual(mod.PLUGIN_BY_ID.auto_chat_demo.title, '接口示例')
        mod.debug_set_open(True)
        lua.execute('for i=1,601 do update() end')
        self.click(lua, h, mod, 'tab:auto_chat_demo')
        self.assertEqual(mod.debug_panel().active_plugin, 'auto_chat_demo')
        before = mod.debug_panel_signature()
        self.click(lua, h, mod, 'plugin:auto_chat_demo:toggle')
        self.assertNotEqual(mod.debug_panel_signature(), before)
        self.assertEqual(h.call_count(), 0)
        self.click(lua, h, mod, 'plugin:auto_chat_demo:send')
        self.assertEqual(h.call_count(), 1)
        self.click(lua, h, mod, 'plugin:auto_chat_demo:send')
        self.assertEqual(h.call_count(), 1, 'example obeys shared minimum interval')
        self.assertTrue(mod.debug_automation().set('enabled', False)[0])
        self.click(lua, h, mod, 'plugin:auto_chat_demo:send')
        self.assertEqual(h.call_count(), 1, 'master switch applies to registered addons')

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


if __name__ == '__main__':
    unittest.main()
