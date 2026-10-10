"""Alert rules layout integration through the production panel and UX helpers."""
import unittest

from test_auto_chat_probe import SOURCE, fresh_image


class AlertLayoutIntegrationTests(unittest.TestCase):
    def setup_alert(self, locale):
        lua, harness = fresh_image(font_ids=True)
        mod = harness.load(SOURCE)
        mod.debug_set_open(True)
        lua.execute('for i=1,700 do update() end')
        harness.res_w, harness.res_h = 960, 540
        mod.debug_language().update('zh', mod.frames)
        mod.ui_preview_language = locale
        panel = mod.debug_panel()
        panel.rule_view = 'stratagem'
        panel.rule_selected = 41
        panel.rule_page = 1
        panel.rule_filter = 'all'
        panel.rule_search = ''
        panel.hint = 'Layout status remains readable after scrolling.'
        rows = lua.table()
        rows[1] = lua.table_from({
            'id': 41, 'name': '中文超长任务战备名称测试',
            'display_name': '中文超长任务战备名称测试',
            'display_name_en': 'Long English Mission Stratagem Title That Must Wrap Across Several Lines',
            'debug_name': 'MISSION.LAYOUT.PROBE',
            'group': 'mission category deliberately extended for wrapping',
            'family': 'mission', 'cooldown': 120,
            'variant_ids': lua.table_from([41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52]),
        })
        catalog = mod.debug_stratagem_catalog()
        catalog.list = lambda: rows
        catalog.list_rules = lambda: rows
        catalog.scan = lambda *_: (1, 'layout fixture')
        catalog.state.ready = True
        catalog.state.status = 'layout fixture'
        lua.execute(r'''
            stingray.Gui.text_extents=function(gui,value,font,size)
                local width=0
                for i=1,#tostring(value) do
                    local byte=tostring(value):byte(i)
                    if byte<128 then width=width+size*0.7
                    elseif byte>=224 then width=width+size end
                end
                return {x=0},{x=width}
            end
            preview_drawn,layout_metrics,layout_rects={},{},{}
            local original_text=stingray.Gui.text
            stingray.Gui.text=function(gui,value,font,size,material,position,color)
                layout_metrics[#layout_metrics+1]={text=tostring(value),size=size,
                    x=position.x,y=position.y}
                preview_drawn[#preview_drawn+1]=tostring(value)
                return original_text(gui,value,font,size,material,position,color)
            end
            local original_rect=stingray.Gui.rect
            stingray.Gui.rect=function(gui,position,size,material)
                layout_rects[#layout_rects+1]={x=position.x,y=position.y,w=size.x,h=size.y}
                return original_rect(gui,position,size,material)
            end
        ''')
        panel.sig = None
        lua.eval('update()')
        return lua, harness, mod, panel

    @staticmethod
    def rendered(lua):
        rows=lua.globals().preview_drawn
        return '\n'.join(str(rows[i]) for i in range(1,len(rows)+1))

    @staticmethod
    def region(panel, key):
        return next(panel.regions[i] for i in range(1, len(panel.regions) + 1)
                    if str(panel.regions[i].key) == key)

    def test_production_wrap_buttons_and_first_viewport_line_at_low_resolution(self):
        for locale, title in (('en', 'Long English Mission Stratagem Title'),
                              ('zh', '中文超长任务战备名称测试')):
            with self.subTest(locale=locale):
                lua, harness, mod, panel = self.setup_alert(locale)
                rendered = self.rendered(lua)
                collapsed = ''.join(rendered.split())
                if locale == 'en':
                    self.assertIn('LongEnglishMissionStratagemTitle', collapsed)
                    self.assertIn('MISSION', collapsed)
                else:
                    self.assertIn('中文超长任务战备名称测试', collapsed)
                if locale == 'en':
                    self.assertIn('DISABLEALL', collapsed)
                    self.assertIn('RESET', collapsed)
                self.assertNotIn('MISSION..', collapsed)
                self.assertNotIn('DISABLE..', collapsed)
                self.assertGreater(panel.viewports.rules_detail.max, 0)
                self.assertGreater(len(lua.globals().layout_metrics), 0)
                # Production UX.text drops a baseline that falls above the viewport;
                # seeing the title on the initial draw proves start padding is applied.
                self.assertGreater(float(self.region(panel, 'rules:bulk:mission:off').h), 0)
                self.assertGreater(float(self.region(panel, 'rules:filter:mission').h), 0)
                for key in ('rules:bulk:mission:off', 'rules:filter:mission'):
                    hit = self.region(panel, key)
                    self.assertTrue(any(
                        abs(float(lua.globals().layout_rects[i].x)-float(hit.x)) < 1.1
                        and abs(float(lua.globals().layout_rects[i].y)-float(hit.y)) < 1.1
                        and abs(float(lua.globals().layout_rects[i].w)-float(hit.w)) < 1.1
                        and abs(float(lua.globals().layout_rects[i].h)-float(hit.h)) < 1.1
                        for i in range(1, len(lua.globals().layout_rects)+1)
                    ), key)

                panel.scroll_offsets.rules_detail = panel.viewports.rules_detail.max
                panel.sig = None
                lua.globals().preview_drawn = lua.table()
                lua.eval('update()')
                scrolled = self.rendered(lua)
                self.assertIn('{position}', scrolled)
                self.assertIn('Layoutstatusremainsreadableafterscrolling',
                              ''.join(scrolled.split()))
                if locale == 'en':
                    self.assertIn('RESTORE MESSAGE', scrolled)
                self.assertIn('{player_name}', scrolled)

    def test_tall_plugin_tabs_move_alert_body_and_preserve_viewport(self):
        lua, harness, mod, panel = self.setup_alert('en')
        before_height = float(panel.viewports.rules_detail.screen_h)
        lua.execute(r'''
            HD2AutoChat.register_plugin({id='layout_tabs_probe',
                title=string.rep('LONG TAB TITLE ', 6), draw=function() end})
        ''')
        self.assertIn('layout_tabs_probe', {str(mod.PLUGINS[i].id)
                                            for i in range(1, len(mod.PLUGINS)+1)})
        panel.sig = None
        lua.globals().preview_drawn = lua.table()
        lua.globals().layout_rects = lua.table()
        lua.eval('update()')
        after = panel.viewports.rules_detail
        rendered = self.rendered(lua)
        self.assertIn('Long English Mission Stratagem Title', rendered.replace('\n', ' '))
        self.assertLess(float(after.screen_h), before_height)
        self.assertIn('rules:inherit', {str(panel.regions[i].key)
                                       for i in range(1, len(panel.regions) + 1)})
        self.assertGreater(panel.viewports.rules_detail.max, 0)
        hit = self.region(panel, 'rules:enabled')
        rects = lua.globals().layout_rects
        self.assertTrue(any(
            abs(float(rects[i].x)-float(hit.x)) < 1.1
            and abs(float(rects[i].y)-float(hit.y)) < 1.1
            and abs(float(rects[i].w)-float(hit.w)) < 1.1
            and abs(float(rects[i].h)-float(hit.h)) < 1.1
            for i in range(1, len(rects) + 1)
        ), 'rules:enabled hitbox must match its button after tabs grow')

    def test_batch_controls_fit_viewport_and_hitboxes_match_drawn_rects_after_tab_growth(self):
        lua, harness, mod, panel = self.setup_alert('en')
        initial_height = float(panel.viewports.rules_detail.screen_h)
        lua.execute(r'''
            HD2AutoChat.register_plugin({id='batch_tabs_probe',
                title=string.rep('LONG TAB TITLE ', 6), draw=function() end})
        ''')
        panel.rule_batch_edit = True
        panel.scroll_offsets.rules_detail = 0
        panel.sig = None
        lua.globals().preview_drawn = lua.table()
        lua.globals().layout_metrics = lua.table()
        lua.globals().layout_rects = lua.table()
        lua.eval('update()')
        rendered = self.rendered(lua)
        collapsed = ''.join(rendered.split())
        self.assertIn('APPLIESTOALLFILTERMATCHES', collapsed)
        self.assertIn('LONGTABTITLE', collapsed)
        self.assertLess(float(panel.viewports.rules_detail.screen_h), initial_height)
        self.assertGreater(panel.viewports.rules_detail.max, 0)
        expected = {'rules:batch:edit:mark_message', 'rules:batch:edit:call_message',
                    'rules:batch:edit:cooldown', 'rules:batch:apply:mark_message',
                    'rules:batch:reset:mark_message', 'rules:batch:apply:call_message',
                    'rules:batch:reset:call_message', 'rules:batch:apply:cooldown',
                    'rules:batch:reset:cooldown', 'rules:inherit'}
        observed = set()
        offsets = (0, float(panel.viewports.rules_detail.max) / 2,
                   float(panel.viewports.rules_detail.max))
        for offset in offsets:
            panel.scroll_offsets.rules_detail = offset
            panel.sig = None
            lua.globals().preview_drawn = lua.table()
            lua.globals().layout_metrics = lua.table()
            lua.globals().layout_rects = lua.table()
            lua.eval('update()')
            if offset == offsets[-1]:
                self.assertIn('RESTOREMESSAGE', ''.join(self.rendered(lua).split()))
            keys = {str(panel.regions[i].key) for i in range(1, len(panel.regions) + 1)}
            observed.update(keys)
            rects = lua.globals().layout_rects
            for key in keys & {item for item in expected if item != 'rules:inherit'}:
                hit = self.region(panel, key)
                self.assertTrue(any(
                    abs(float(rects[i].x)-float(hit.x)) < 1.1
                    and abs(float(rects[i].y)-float(hit.y)) < 1.1
                    and abs(float(rects[i].w)-float(hit.w)) < 1.1
                    and abs(float(rects[i].h)-float(hit.h)) < 1.1
                    for i in range(1, len(rects) + 1)
                ), f'{key} hitbox must match its clipped visible rectangle')
        self.assertTrue(expected <= observed, f'missing scrolled controls: {expected-observed}')


if __name__ == '__main__':
    unittest.main()
