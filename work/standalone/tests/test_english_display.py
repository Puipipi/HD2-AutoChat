"""Production draw-path regressions for English UI text containing CJK."""
import unittest

from test_auto_chat_probe import SOURCE, fresh_image


def contains_cjk(text):
    return any(
        0x2E80 <= ord(ch) <= 0x2EFF
        or 0x3000 <= ord(ch) <= 0x303F
        or 0x3100 <= ord(ch) <= 0x312F
        or 0x31A0 <= ord(ch) <= 0x31BF
        or 0x31C0 <= ord(ch) <= 0x31EF
        or 0x3400 <= ord(ch) <= 0x4DBF
        or 0x4E00 <= ord(ch) <= 0x9FFF
        or 0xF900 <= ord(ch) <= 0xFAFF
        or 0xFE30 <= ord(ch) <= 0xFE4F
        or 0xFF00 <= ord(ch) <= 0xFFEF
        or 0x20000 <= ord(ch) <= 0x2FA1F
        for ch in text
    )


LUA_CJK_PREDICATES = r'''
local function has_cjk_text(value)
    local i=1
    while i<=#value do
        local a=value:byte(i)
        local cp,step
        if a<0x80 then cp,step=a,1
        elseif a<0xE0 then cp,step=(a-0xC0)*0x40+(value:byte(i+1) or 0)-0x80,2
        elseif a<0xF0 then cp,step=(a-0xE0)*0x1000+((value:byte(i+1) or 0)-0x80)*0x40+(value:byte(i+2) or 0)-0x80,3
        else cp,step=(a-0xF0)*0x40000+((value:byte(i+1) or 0)-0x80)*0x1000+((value:byte(i+2) or 0)-0x80)*0x40+(value:byte(i+3) or 0)-0x80,4 end
        if (cp>=0x2E80 and cp<=0x2EFF) or (cp>=0x3000 and cp<=0x303F)
            or (cp>=0x3100 and cp<=0x312F) or (cp>=0x31A0 and cp<=0x31EF)
            or (cp>=0x3400 and cp<=0x4DBF) or (cp>=0x4E00 and cp<=0x9FFF)
            or (cp>=0xF900 and cp<=0xFAFF) or (cp>=0xFE30 and cp<=0xFE4F)
            or (cp>=0xFF00 and cp<=0xFFEF) or (cp>=0x20000 and cp<=0x2FA1F) then
            return true
        end
        i=i+step
    end
    return false
end
function table_has_cjk(values)
    for i=1,#values do if has_cjk_text(tostring(values[i])) then return true end end
    return false
end
function table_has_exact(values, expected)
    for i=1,#values do if values[i]==expected then return true end end
    return false
end
function table_has_substring(values, expected)
    for i=1,#values do if tostring(values[i]):find(expected,1,true) then return true end end
    return false
end
function test_send_call_equals(call,expected) return call.arg3_text==expected..'\0' end
'''


class EnglishDisplayTests(unittest.TestCase):
    def make_panel(self):
        lua, harness = fresh_image(font_ids=True)
        mod = harness.load(SOURCE)
        lua.execute(LUA_CJK_PREDICATES)
        mod.debug_language().update('en', 1)
        lua.execute("""
            assert(HD2AutoChat.add_task('中文任务名', 'repeat', '30',
                '保留的中文发送消息，ID-42', nil, 'host'))
            assert(HD2AutoChat.debug_preset_library().save('用户中文预设', 'host'))
            local catalog=HD2AutoChat.debug_stratagem_catalog()
            local row={id=4119049995,type=3,name='EAGLE. 500KG BOMB',
                debug_name='EAGLE. 500KG BOMB',name_key=2994328991,
                name_upper_key=1057738842,display_name='“飞鹰”500KG炸弹',
                display_name_en='Eagle 500kg Bomb',group='red',family='stratagem',
                cooldown=15,variant_ids={4119049995},native_name_missing={zh=false,en=true},
                _panel_native_names={['en:98']='中文本地化战备'} }
            catalog.state.ready=true; catalog.state.generation=98
            catalog.state.entries={row}; catalog.state.rules={row}
            catalog.state.status='Stratagem catalog ready (1)'
            local automation=HD2AutoChat.debug_automation()
            assert(automation.set('ping_message','默认中文标记：{target}','host'))
            assert(automation.set_rule('stratagem',4119049995,'mark_message',
                '单项中文标记：{target}','host'))
            assert(automation.set_rule('enemy','small_enemy','mark_message',
                '敌人中文提醒：{target}','host'))
            local registry = rawget(_G, 'HD2AutoChatPlugins')
            assert(registry.register({id='cjk_display_probe', title='DISPLAY PROBE',
                name_en='DISPLAY PROBE', draw=function(ui)
                    ui.text('PLUGIN 㐀豈𠀀内容：保留英文 ID-42', 12, 18, 14, nil, 700)
                    ui.text('INVALID '..string.char(0xF0,0x80,0x80,0x80)..' ID-42', 12, 42, 14, nil, 700)
                    ui.text('NON-CJK é Ω カナ 한글 ID-43', 12, 66, 14, nil, 700)
                end}))
            local original = stingray.Gui.text
            _G.display_drawn = {}
            stingray.Gui.text = function(gui, value, ...)
                display_drawn[#display_drawn+1] = tostring(value)
                return original(gui, value, ...)
            end
            local extents = stingray.Gui.text_extents
            _G.display_measured = {}
            stingray.Gui.text_extents = function(gui, value, ...)
                display_measured[#display_measured+1] = tostring(value)
                return extents(gui, value, ...)
            end
        """)
        mod.debug_set_open(True)
        lua.execute('for i=1,620 do update() end')
        self.assertEqual('en', str(mod.debug_language().current()))
        return lua, harness, mod

    @staticmethod
    def captured(lua, key='display_drawn'):
        table = lua.globals()[key]
        return [str(table[i]) for i in range(1, len(table) + 1)]

    def draw_state(self, lua, mod, script):
        lua.execute(script + """
            local catalog=HD2AutoChat.debug_stratagem_catalog()
            catalog.scan=function() return 1,catalog.state.status end
            local p=HD2AutoChat.debug_panel(); p.version=p.version+1; update()
        """)
        return self.captured(lua)

    def test_production_english_draws_hide_cjk_on_every_owned_page_and_plugin_canvas(self):
        lua, harness, mod = self.make_panel()
        states = {
            'tasks and details': "local p=HD2AutoChat.debug_panel(); p.active_plugin=nil; p.rule_view=nil; p.preset_view=nil; p.settings_view='tasks'; p.selected_task_detail_id=1",
            'automation': "local p=HD2AutoChat.debug_panel(); p.active_plugin=nil; p.rule_view=nil; p.preset_view=nil; p.settings_view='automation'",
            'pings': "local p=HD2AutoChat.debug_panel(); p.active_plugin=nil; p.rule_view=nil; p.preset_view=nil; p.settings_view='pings'",
            'stratagem rule and native-name detail': "local p=HD2AutoChat.debug_panel(); p.active_plugin=nil; p.preset_view=nil; p.rule_view='stratagem'; p.rule_selected=4119049995",
            'enemy rule and custom message': "local p=HD2AutoChat.debug_panel(); p.active_plugin=nil; p.preset_view=nil; p.rule_view='enemy'; p.rule_selected='small_enemy'",
            'presets': "local p=HD2AutoChat.debug_panel(); p.active_plugin=nil; p.rule_view=nil; p.preset_view=true",
            'plugin canvas': "local p=HD2AutoChat.debug_panel(); p.rule_view=nil; p.preset_view=nil; p.active_plugin='cjk_display_probe'",
        }
        for label, script in states.items():
            with self.subTest(page=label):
                lua.execute('display_drawn={}\ndisplay_measured={}')
                strings = self.draw_state(lua, mod, script)
                self.assertTrue(strings, f'{label} must exercise the production Gui.text path')
                self.assertFalse(lua.eval('table_has_cjk(display_drawn)'),
                                 f'{label} passed CJK into Gui.text: {strings[:12]}')
                if label == 'plugin canvas':
                    self.assertTrue(lua.eval("table_has_substring(display_drawn, '[Chinese text hidden]')"))
                    self.assertTrue(lua.eval("table_has_substring(display_drawn, 'ID-42')"),
                                    'plugin text and readable ASCII fragments must reach draw')
                    self.assertTrue(lua.eval("table_has_substring(display_drawn, ':[Chinese text hidden]')"),
                                    'fullwidth colon should become ASCII while hidden CJK stays omitted')
                    self.assertTrue(lua.eval("table_has_substring(display_drawn, 'INVALID ???? ID-42')"),
                                    'invalid UTF-8 must not pass through to the game font')
                    self.assertTrue(lua.eval("table_has_substring(display_drawn, 'NON-CJK é Ω カナ 한글 ID-43')"),
                                    'non-Chinese Unicode remains source-identical in display')
                if label == 'stratagem rule and native-name detail':
                    self.assertTrue(lua.eval("table_has_substring(display_drawn, '4119049995')"))
                    self.assertTrue(lua.eval("table_has_substring(display_drawn, 'ID ')"))

    def test_english_placeholder_is_used_for_measurement_and_input_tail_without_mutation(self):
        lua, harness, mod = self.make_panel()
        lua.execute("""
            local p=HD2AutoChat.debug_panel()
            p.active_plugin=nil; p.preset_view=nil; p.settings_view='tasks';
            p.rule_view='stratagem'; p.edit_field='rules:search'; p.editing=true
            p.edit_text='搜索词：㐀豈𠀀中文-42'
            p.version=p.version+1
            display_drawn={}; display_measured={}
            update()
        """)
        drawn = self.captured(lua)
        measured = self.captured(lua, 'display_measured')
        self.assertTrue(lua.eval("table_has_substring(display_drawn, '[Chinese text hidden]')"), drawn)
        self.assertTrue(lua.eval("table_has_substring(display_drawn, '..:[Chinese text hidden]-42_')"),
                        'input tail keeps hidden-text markers atomic and retains the caret/ASCII suffix')
        self.assertFalse(lua.eval('table_has_cjk(display_drawn)'))
        self.assertFalse(lua.eval('table_has_cjk(display_measured)'))
        self.assertTrue(lua.eval("HD2AutoChat.debug_panel().edit_text=='搜索词：㐀豈𠀀中文-42'"),
                        'display conversion must not overwrite the live edit buffer')
        self.assertTrue(lua.eval("HD2AutoChat.tasks[1].name=='中文任务名'"))
        self.assertTrue(lua.eval("HD2AutoChat.tasks[1].message=='保留的中文发送消息，ID-42'"))
        self.assertTrue(lua.eval("""(function()
            for _,entry in ipairs(HD2AutoChat.debug_preset_library().list('host')) do
                if entry.name=='用户中文预设' then return true end
            end
            return false
        end)()"""))

    def test_english_locale_does_not_change_task_or_outbound_utf8(self):
        lua, harness, mod = self.make_panel()
        lua.execute("""
            local p=HD2AutoChat.debug_panel()
            p.active_plugin=nil; p.preset_view=nil; p.rule_view='stratagem'
            p.version=p.version+1; display_drawn={}; display_measured={}; update()
        """)
        self.assertFalse(lua.eval('table_has_cjk(display_drawn)'))
        self.assertTrue(lua.eval("HD2AutoChat.tasks[1].name=='中文任务名'"))
        self.assertTrue(lua.eval("HD2AutoChat.tasks[1].message=='保留的中文发送消息，ID-42'"))
        sent, _ = lua.eval("HD2AutoChat.send_text('出站中文原文-42', false, true)")
        self.assertTrue(sent)
        # Pass the production Lua record back into Lua for byte-exact comparison;
        # Python's console code page is deliberately not part of this assertion.
        self.assertTrue(lua.eval('test_send_call_equals')(harness.last_call(), '出站中文原文-42'))

    def test_chinese_locale_keeps_custom_text_visible(self):
        lua, _, mod = self.make_panel()
        mod.debug_language().update('zh', 700)
        lua.execute("""
            local p=HD2AutoChat.debug_panel()
            p.active_plugin=nil; p.preset_view=true; p.rule_view=nil
            p.version=p.version+1; display_drawn={}; display_measured={}; update()
        """)
        self.assertTrue(lua.eval('table_has_cjk(display_drawn)'),
                        'Chinese locale should preserve native custom preset names')
        self.assertTrue(lua.eval("HD2AutoChat.tasks[1].name=='中文任务名'"))

    def test_english_ping_labels_and_variable_help_are_ascii_at_each_scroll_position(self):
        lua, _, mod = self.make_panel()
        for enabled in (False, True):
            lua.eval('HD2AutoChat.debug_automation().set')("ping", enabled, "host")
            for offset in (0, 120, 99999):
                with self.subTest(enabled=enabled, offset=offset):
                    lua.execute('display_drawn={}; display_measured={}')
                    strings = self.draw_state(lua, mod, f"""
                        local p=HD2AutoChat.debug_panel()
                        p.active_plugin=nil; p.rule_view=nil; p.preset_view=nil
                        p.settings_view='pings'; p.scroll_offsets.pings={offset}
                    """)
                    non_ascii = [(value, [f'U+{ord(ch):04X}' for ch in value if ord(ch)>127])
                                 for value in strings if any(ord(ch)>127 for ch in value)]
                    self.assertEqual([], non_ascii,
                                     'fixed English Ping-page labels and help should be printable ASCII')
                    if offset == 99999:
                        self.assertIn('{abbr} / {slot}', strings,
                                      'both supported message tokens should remain visible')
        lua.execute('display_drawn={}; display_measured={}')
        task_strings = self.draw_state(lua, mod, """
            local p=HD2AutoChat.debug_panel(); p.active_plugin=nil
            p.rule_view=nil; p.preset_view=nil; p.settings_view='tasks'
        """)
        self.assertTrue(any('CLICK ADD TASK TO SAVE THE' in s for s in task_strings),
                        'task helper wording should remain understandable without typographic quotes')
        self.assertFalse(any(any(ord(ch)>127 for ch in s) for s in task_strings))
        lua.execute('display_drawn={}; display_measured={}')
        rule_strings = self.draw_state(lua, mod, """
            local p=HD2AutoChat.debug_panel(); p.active_plugin=nil
            p.rule_view='stratagem'; p.preset_view=nil; p.rule_selected=4119049995
            p.scroll_offsets.rules=99999
        """)
        self.assertFalse(any(any(ord(ch)>127 for ch in s) for s in rule_strings),
                         'English rule labels/help should use printable ASCII')
        self.assertTrue(any('RULE ID 4119049995 / red / GAME CD 15s' in s for s in rule_strings),
                        'rule identity, group and cooldown remain visible after separator change')
        self.assertIn('{abbr} / {slot}', rule_strings)

    def test_ping_statuses_are_translated_in_real_english_draw_and_preserved_in_chinese(self):
        lua, _, mod = self.make_panel()
        ping_statuses = {
            '等待标记数据': 'Waiting for ping data',
            '标记计时不可用': 'Ping timer unavailable',
            '标记数据暂不可用': 'Ping data temporarily unavailable',
            '标记数据切换中': 'Ping data is changing',
            '已记录现有标记': 'Existing pings recorded',
            '已识别玩家标记': 'Player ping detected',
            '等待新的玩家标记': 'Waiting for the next ping',
            '标记消息已关闭': 'Ping messages are off',
        }
        task_statuses = {
            '等待任务战备数据': 'Waiting for task stratagem data',
            '任务战备：不支持的游戏版本': 'Mission stratagems: unsupported game version',
            '任务战备数据暂不可读': 'Mission stratagem data temporarily unreadable',
            '任务战备数据切换中': 'Mission stratagem data is updating',
            '任务战备读取就绪': 'Mission stratagem alerts ready',
            '任务战备消息已关闭': 'Task stratagem messages are off',
        }
        for field, status_map in (('ping_status', ping_statuses),
                                  ('task_stratagem_status', task_statuses)):
            for raw, expected in status_map.items():
                with self.subTest(field=field, status=raw):
                    other = '任务战备读取就绪' if field == 'ping_status' else '等待标记数据'
                    ping = raw if field == 'ping_status' else other
                    task = raw if field == 'task_stratagem_status' else other
                    lua.execute(f"""
                    HD2AutoChat.ping_status={ping!r}
                    HD2AutoChat.task_stratagem_status={task!r}
                    local p=HD2AutoChat.debug_panel(); p.active_plugin=nil
                    p.rule_view=nil; p.preset_view=nil; p.settings_view='pings'
                    p.scroll_offsets.pings=99999
                    display_drawn={{}}; display_measured={{}}; p.version=p.version+1; update()
                """)
                    strings = self.captured(lua)
                    self.assertIn(expected, ' '.join(strings))
                    self.assertFalse(lua.eval('table_has_cjk(display_drawn)'), strings)
                    self.assertFalse(any(any(ord(ch)>127 for ch in s) for s in strings), strings)
        lua.execute('HD2AutoChat.ping_status="标记计时不可用"; HD2AutoChat.task_stratagem_status="任务战备数据切换中"')
        mod.debug_language().update('zh', 700)
        strings = self.draw_state(lua, mod, """
            local p=HD2AutoChat.debug_panel(); p.active_plugin=nil
            p.rule_view=nil; p.preset_view=nil; p.settings_view='pings'
            p.scroll_offsets.pings=99999
        """)
        self.assertIn('标记计时不可用', strings)
        self.assertIn('任务战备数据切换中', strings)



if __name__ == '__main__':
    unittest.main()
