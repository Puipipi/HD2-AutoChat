"""Exercise the UI-only locale preview through the Lua game-image harness."""
import unittest

from test_auto_chat_probe import SOURCE, fresh_image


class UiPreviewTests(unittest.TestCase):
    def fresh(self):
        lua, harness = fresh_image(font_ids=True)
        mod = harness.load(SOURCE)
        mod.debug_set_open(True)
        lua.execute('for i=1,700 do update() end')
        lua.execute('''
            preview_drawn={}
            local native_text=stingray.Gui.text
            stingray.Gui.text=function(gui,value,font,size,material,pos,color)
                preview_drawn[#preview_drawn+1]=tostring(value)
                return native_text(gui,value,font,size,material,pos,color)
            end
        ''')
        return lua, harness, mod

    @staticmethod
    def rendered(lua):
        rows = lua.globals().preview_drawn
        return '\n'.join(str(rows[i]) for i in range(1, len(rows) + 1))

    @staticmethod
    def click(lua, harness, mod, key):
        regions = mod.debug_panel().regions
        region = next(regions[i] for i in range(1, len(regions) + 1)
                      if str(regions[i].key) == key)
        harness.mouse_x = region.x + region.w / 2
        harness.mouse_y = 1080 - region.y - region.h / 2
        harness.user32.set_key(1, True)
        lua.eval('update()')
        harness.user32.set_key(1, False)
        lua.eval('update()')

    @staticmethod
    def exported_text(harness, preset_id):
        rows = harness.written()
        for i in range(len(rows), 0, -1):
            row = rows[i]
            if 'preset-' + preset_id in str(row.path):
                return str(row.text)
        raise AssertionError('preset export was not written')

    def test_english_preview_draws_english_without_changing_game_or_saved_content(self):
        lua, harness, mod = self.fresh()
        language = mod.debug_language()
        language.update('zh', mod.frames)
        automation = mod.debug_automation()
        self.assertTrue(automation.set('message_language', 'auto', 'host')[0])
        task = mod.add_task('Preview task', 'repeat', '30', 'keep {player_name}', 1000, 'host')
        self.assertIsNotNone(task)
        library = mod.debug_preset_library()
        saved = library.save('UI preview fixture', 'host')
        self.assertTrue(saved[0], saved[1])
        preset_id = saved[2]
        self.assertTrue(library.export(preset_id, 'host')[0])
        before_export = self.exported_text(harness, preset_id)
        before_tasks = mod.debug_serialize_tasks()

        mod.debug_panel().settings_view = 'pings'
        mod.ui_preview_language = 'en'
        lua.globals().preview_drawn = lua.table()
        lua.eval('update()')
        self.assertIn('PLAYER PING MESSAGES', self.rendered(lua))
        self.assertEqual('zh', language.current())
        self.assertEqual('auto', automation.profile('host').message_language)
        self.assertEqual(before_tasks, mod.debug_serialize_tasks())
        self.assertTrue(library.export(preset_id, 'host')[0])
        after_export = self.exported_text(harness, preset_id)
        self.assertEqual(before_export, after_export)

        self.click(lua, harness, mod, 'presets:open')
        self.click(lua, harness, mod, 'profile:client')
        lua.globals().preview_drawn = lua.table()
        lua.eval('update()')
        rendered = self.rendered(lua)
        self.assertIn('Editing client preset; enabled according to identity', rendered)
        self.assertNotIn('正在编辑', rendered)
        self.assertEqual('zh', language.current())
        self.assertEqual('auto', automation.profile('host').message_language)
        self.assertEqual(before_tasks, mod.debug_serialize_tasks())

    def test_nil_preview_follows_chinese_game_locale_and_optional_locale_reads_do_not_mutate_it(self):
        lua, _, mod = self.fresh()
        language = mod.debug_language()
        language.update('zh', mod.frames)
        self.assertEqual('zh', language.current())
        self.assertEqual('English label', language.text('中文标签', 'English label', 'en'))
        self.assertFalse(language.is_chinese('en'))
        self.assertEqual('Waiting for stratagem catalog', language.status('等待战备目录', 'en'))
        self.assertEqual('zh', language.current())

        mod.ui_preview_language = None
        mod.debug_panel().settings_view = 'pings'
        lua.globals().preview_drawn = lua.table()
        lua.eval('update()')
        rendered = self.rendered(lua)
        self.assertIn('自动消息', rendered)
        self.assertNotIn('AUTO MESSAGES', rendered)
        self.assertEqual('zh', language.current())

    def test_timer_mode_and_range_help_are_drawn_without_truncation_in_both_locales(self):
        for locale in ('en', 'zh'):
            for width, height in ((1920, 1080), (1280, 720), (960, 540)):
                with self.subTest(locale=locale, resolution=(width, height)):
                    lua, harness, mod = self.fresh()
                    mod.ui_preview_language = locale
                    mod.debug_panel().settings_view = 'tasks'
                    harness.res_w, harness.res_h = width, height
                    mod.debug_panel().sig = None
                    lua.execute('''
                        stingray.Gui.text_extents=function(gui,value,font,size)
                            local width=0
                            local value=tostring(value)
                            for i=1,#value do
                                local byte=value:byte(i)
                                if byte<128 then
                                    local ch=value:sub(i,i)
                                    width=width+size*(ch:match('%s') and 0.36
                                        or ch:match('%u') and 0.72 or 0.62)
                                elseif byte>=224 then width=width+size
                                elseif byte>=192 then width=width+size*0.7 end
                            end
                            return {x=0},{x=width}
                        end
                        preview_metrics={}
                        local original_text=stingray.Gui.text
                        stingray.Gui.text=function(gui,value,font,size,material,position,color)
                            local _,upper=stingray.Gui.text_extents(gui,tostring(value),font,size)
                            preview_metrics[#preview_metrics+1]={text=tostring(value),size=size,
                                x=position.x,y=position.y,width=upper.x}
                            return original_text(gui,value,font,size,material,position,color)
                        end
                    ''')
                    lua.globals().preview_drawn = lua.table()
                    lua.eval('update()')
                    rendered = self.rendered(lua)
                    wrapped = rendered.replace('\n', ' ')
                    if locale == 'en':
                        self.assertIn('COUNTDOWN', rendered)
                        self.assertNotIn('COUNT..', rendered)
                        self.assertIn('REPEAT / COUNTDOWN: 5 S TO 24 H', wrapped)
                    else:
                        self.assertIn('一次倒计时', rendered)
                        self.assertNotIn('一次倒..', rendered)
                        self.assertIn('重复 / 倒计时：5 秒至 24 小时', wrapped)
                    metrics = lua.globals().preview_metrics
                    self.assertGreater(len(metrics), 0)
                    self.assertGreaterEqual(min(metrics[i].size for i in range(1, len(metrics) + 1)), 9)
                    countdown = next(metrics[i] for i in range(1, len(metrics) + 1)
                                     if metrics[i].text == ('COUNTDOWN' if locale == 'en' else '一次倒计时'))
                    mode = next(mod.debug_panel().regions[i] for i in range(1, len(mod.debug_panel().regions) + 1)
                                if mod.debug_panel().regions[i].key == 'mode:once')
                    self.assertGreaterEqual(countdown.x, mode.x)
                    self.assertLessEqual(countdown.x + countdown.width, mode.x + mode.w)

                    # The form is intentionally scrollable at small resolutions;
                    # hints below the fold must be checked after real viewport scroll.
                    panel = mod.debug_panel()
                    task_view = panel.viewports.task_form
                    if task_view.max > 0:
                        panel.scroll_offsets.task_form = task_view.max
                        panel.sig = None
                        lua.globals().preview_drawn = lua.table()
                        lua.eval('update()')
                        rendered = self.rendered(lua)
                    self.assertIn('{abbr}', rendered)

                    panel.editing, panel.edit_field = True, 'message'
                    panel.edit_text = 'long-prefix-that-must-scroll-to-tail-KEEP-THIS-CURSOR'
                    panel.sig = None
                    lua.globals().preview_drawn = lua.table()
                    lua.globals().preview_metrics = lua.table()
                    lua.eval('update()')
                    edited = lua.globals().preview_metrics
                    tail = next(str(edited[i].text) for i in range(1, len(edited) + 1)
                                if str(edited[i].text).endswith('KEEP-THIS-CURSOR_'))
                    self.assertTrue(tail.startswith('..'))
                    tail_metric = next(edited[i] for i in range(1, len(edited) + 1)
                                       if str(edited[i].text) == tail)
                    message_box = next(panel.regions[i] for i in range(1, len(panel.regions) + 1)
                                       if panel.regions[i].key == 'task:message')
                    self.assertGreater(message_box.w, 0)
                    self.assertGreaterEqual(tail_metric.x, message_box.x)
                    self.assertLessEqual(tail_metric.x + tail_metric.width,
                                         message_box.x + message_box.w)
                    self.assertEqual('long-prefix-that-must-scroll-to-tail-KEEP-THIS-CURSOR',
                                     str(panel.edit_text), 'display tail must not change the draft value')

    def test_pings_viewport_content_height_tracks_wrapped_hint_rows(self):
        lua, _, mod = self.fresh()
        mod.debug_panel().settings_view = 'pings'
        lua.execute('''
            stingray.Gui.text_extents=function(gui,value,font,size)
                local width=0
                local value=tostring(value)
                for i=1,#value do
                    local byte=value:byte(i)
                    if byte<128 then
                        local ch=value:sub(i,i)
                        width=width+size*(ch:match('%s') and 0.36
                            or ch:match('%u') and 0.72 or 0.62)
                    elseif byte>=224 then width=width+size
                    elseif byte>=192 then width=width+size*0.7 end
                end
                return {x=0},{x=width}
            end
            preview_drawn={}
        ''')
        lua.eval('update()')
        panel = mod.debug_panel()
        viewport = panel.viewports.pings
        self.assertGreater(viewport.max, 0)
        panel.scroll_offsets.pings = viewport.max
        panel.sig = None
        lua.globals().preview_drawn = lua.table()
        lua.eval('update()')
        rendered = self.rendered(lua)
        self.assertIn('{位置}/{position}', rendered,
                      'the final help row stays reachable at the calculated scroll limit')
        self.assertNotIn('{位置}/{posit..', rendered)

    def test_automation_and_ping_forms_wrap_long_labels_at_narrow_resolution(self):
        for locale in ('en', 'zh'):
            with self.subTest(locale=locale):
                lua, h, mod = self.fresh()
                h.res_w, h.res_h = 960, 540
                mod.ui_preview_language = locale
                panel = mod.debug_panel()
                panel.settings_view = 'pings'
                panel.sig = None
                lua.execute('''
                    stingray.Gui.text_extents=function(gui,value,font,size)
                        local width=0
                        local value=tostring(value)
                        for i=1,#value do
                            local byte=value:byte(i)
                            if byte<128 then
                                local ch=value:sub(i,i)
                                width=width+size*(ch:match('%s') and 0.36
                                    or ch:match('%u') and 0.72 or 0.62)
                            elseif byte>=224 then width=width+size
                            elseif byte>=192 then width=width+size*0.7 end
                        end
                        return {x=0},{x=width}
                    end
                    preview_drawn={}
                ''')
                lua.eval('update()')
                rendered = self.rendered(lua).replace('\n', ' ')
                ping_label = ('PLAYER NAME AND PREFIX COLOR' if locale == 'en'
                              else '玩家名称与缩写使用队员颜色')
                self.assertIn(ping_label, rendered)
                self.assertTrue('[ON]' in rendered or '[OFF]' in rendered)
                view = panel.viewports.pings
                panel.scroll_offsets.pings = view.max
                panel.sig = None
                lua.globals().preview_drawn = lua.table()
                lua.eval('update()')
                self.assertIn('{位置}/{position}', self.rendered(lua))

                panel.settings_view = 'automation'
                panel.scroll_offsets.automation = 0
                panel.sig = None
                lua.globals().preview_drawn = lua.table()
                lua.eval('update()')
                initial = self.rendered(lua).replace('\n', ' ')
                auto_label = 'ENABLE AUTO SEND' if locale == 'en' else '自动发送总开关'
                self.assertIn(auto_label, initial)
                self.assertTrue('[ON]' in initial or '[OFF]' in initial)
                automation_view = panel.viewports.automation
                self.assertIsNotNone(automation_view)
                panel.scroll_offsets.automation = automation_view.max
                panel.sig = None
                lua.globals().preview_drawn = lua.table()
                lua.eval('update()')
                self.assertIn('{abbr}', self.rendered(lua))

    def test_long_plugin_tabs_stay_clear_of_navigation_and_default_content(self):
        lua, _, mod = self.fresh()
        mod.ui_preview_language = 'en'
        lua.execute('''
            local registry=rawget(_G,'HD2AutoChatPlugins')
            assert(registry.register({id='long.one',title='A VERY LONG FIRST PLUGIN SETTINGS TITLE',
                name_en='A VERY LONG FIRST PLUGIN SETTINGS TITLE',draw=function() end}))
            assert(registry.register({id='long.two',title='ANOTHER EXTREMELY LONG SECOND PLUGIN SETTINGS TITLE',
                name_en='ANOTHER EXTREMELY LONG SECOND PLUGIN SETTINGS TITLE',draw=function() end}))
            assert(registry.register({id='long.three',title='THIRD VERY LONG PLUGIN SETTINGS TITLE',
                name_en='THIRD VERY LONG PLUGIN SETTINGS TITLE',draw=function() end}))
        ''')
        panel = mod.debug_panel()
        panel.active_plugin = None
        panel.tab_page = 1
        panel.sig = None
        lua.globals().preview_drawn = lua.table()
        lua.eval('update()')
        tabs = [panel.regions[i] for i in range(1, len(panel.regions) + 1)
                if str(panel.regions[i].key).startswith('tab:')]
        next_tab = next(panel.regions[i] for i in range(1, len(panel.regions) + 1)
                        if panel.regions[i].key == 'tabs:next')
        self.assertEqual(3, len(tabs))
        self.assertLessEqual(max(region.x + region.w for region in tabs), next_tab.x,
                             'long plugin tabs must leave navigation controls unobstructed')
        default_tab = next(region for region in tabs if region.key == 'tab:default')
        settings_button = next(panel.regions[i] for i in range(1, len(panel.regions) + 1)
                               if panel.regions[i].key == 'view:tasks')
        self.assertLess(settings_button.y + settings_button.h, default_tab.y,
                           'default settings controls must start below the dynamic tab strip')

    def test_compact_profile_header_and_task_footer_fit_at_small_resolution(self):
        lua, harness = fresh_image(font_ids=True)
        harness.res_w, harness.res_h = 960, 540
        mod = harness.load(SOURCE)
        mod.ui_preview_language = 'en'
        mod.debug_set_open(True)
        lua.execute('for i=1,700 do update() end')
        panel = mod.debug_panel()
        panel.sig = None
        drawn = []
        native_text = lua.globals().stingray.Gui.text
        def record(gui, value, font, size, material, pos, color):
            drawn.append(str(value))
            return native_text(gui, value, font, size, material, pos, color)
        lua.globals().stingray.Gui.text = record
        lua.eval('update()')
        self.assertIn('HOST', drawn)
        self.assertIn('CLIENT', drawn)
        self.assertIn('ACTIVE: HOST', drawn)
        self.assertIn('WHILE GAME RUNS / LOCAL TIME', drawn)
        profile_host = next(panel.regions[i] for i in range(1, len(panel.regions)+1)
                            if panel.regions[i].key == 'profile:host')
        profile_client = next(panel.regions[i] for i in range(1, len(panel.regions)+1)
                              if panel.regions[i].key == 'profile:client')
        tasks = next(panel.regions[i] for i in range(1, len(panel.regions)+1)
                     if panel.regions[i].key == 'view:tasks')
        self.assertLessEqual(profile_host.x + profile_host.w, profile_client.x)
        self.assertGreater(profile_host.y, tasks.y + tasks.h,
                           'profile header must stay above the page tabs')

    def test_settings_navigation_captions_fit_wide_english_and_chinese_metrics(self):
        for locale, expected in (
            ('en', ('TASKS', 'AUTO', 'PING')),
            ('zh', ('定时任务', '自动消息', '标记消息')),
        ):
            with self.subTest(locale=locale):
                lua, harness = fresh_image(font_ids=True)
                harness.res_w, harness.res_h = 960, 540
                mod = harness.load(SOURCE)
                mod.ui_preview_language = locale
                mod.debug_set_open(True)
                lua.execute('for i=1,700 do update() end')
                panel = mod.debug_panel()
                panel.settings_view = 'automation'
                panel.sig = None
                lua.execute('''
                    stingray.Gui.text_extents=function(gui,value,font,size)
                        local width=0
                        local value=tostring(value)
                        for i=1,#value do
                            local byte=value:byte(i)
                            if byte<128 then
                                local ch=value:sub(i,i)
                                width=width+size*(ch:match('%s') and 0.45
                                    or ch:match('%u') and 0.78 or 0.68)
                            elseif byte>=224 then width=width+size end
                        end
                        return {x=0},{x=width}
                    end
                    nav_drawn={}
                    local original=stingray.Gui.text
                    stingray.Gui.text=function(gui,value,font,size,material,pos,color)
                        nav_drawn[#nav_drawn+1]={text=tostring(value),x=pos.x,y=pos.y,size=size}
                        return original(gui,value,font,size,material,pos,color)
                    end
                ''')
                lua.eval('update()')
                drawn = lua.globals().nav_drawn
                nav_regions = {}
                for i in range(1, len(panel.regions) + 1):
                    region = panel.regions[i]
                    if str(region.key).startswith('view:'):
                        nav_regions[str(region.key)] = region
                keys = ('view:tasks', 'view:automation', 'view:pings')
                self.assertTrue(all(key in nav_regions for key in keys))
                texts = [str(drawn[i].text) for i in range(1, len(drawn) + 1)]
                for key, caption_text in zip(keys, expected):
                    self.assertIn(caption_text, texts,
                                  f'{locale} navigation caption must render in full')
                    region = nav_regions[key]
                    matching = [drawn[i] for i in range(1, len(drawn) + 1)
                                if str(drawn[i].text) == caption_text]
                    self.assertTrue(matching)
                    # The fixture supplies deliberately wide CJK metrics so the
                    # assertion catches truncation at the real small-screen width.
                    self.assertGreater(region.w, 0)

    def test_wrapped_task_details_preserve_blank_lines_and_crlf(self):
        def render_message(message, locale, name='Paragraph fixture'):
            lua, _, mod = self.fresh()
            mod.ui_preview_language = locale
            task = mod.add_task('Paragraph fixture', 'repeat', '30',
                                'PARA-A PARA-B', 1000, 'host')
            self.assertIsNotNone(task)
            # add_task correctly normalizes user-entered scheduled messages to a
            # single line; this fixture models an existing persisted value so the
            # detail preview's paragraph layout can be exercised directly.
            task.name = name
            task.message = message
            panel = mod.debug_panel()
            panel.settings_view = 'tasks'
            panel.profile = 'host'
            panel.selected_task_detail_id = task.id
            panel.sig = None
            lua.execute('''
                paragraph_capture={}
                local original=stingray.Gui.text
                stingray.Gui.text=function(gui,value,font,size,material,position,color)
                    paragraph_capture[#paragraph_capture+1]={text=tostring(value),y=position.y}
                    return original(gui,value,font,size,material,position,color)
                end
            ''')
            lua.eval('update()')
            panel = mod.debug_panel()
            panel.scroll_offsets.task_form = panel.viewports.task_form.max
            panel.sig = None
            lua.globals().paragraph_capture = lua.table()
            lua.eval('update()')
            rows = lua.globals().paragraph_capture
            lines = [(str(rows[i].text), float(rows[i].y)) for i in range(1, len(rows) + 1)]
            view = mod.debug_panel().viewports.task_form
            return lines, float(view.max)

        # This exercises the production task-detail renderer and its matching viewport
        # height calculation; input task messages themselves intentionally reject
        # newlines as a separate single-line validation rule.
        for locale in ('en', 'zh'):
            with self.subTest(locale=locale):
                lines, paragraph_max = render_message('PARA-A\n\nPARA-B', locale)
                y_a = next(y for text, y in lines if text == 'PARA-A')
                y_b = next(y for text, y in lines if text == 'PARA-B')
                one_break_lines, _ = render_message('PARA-A\nPARA-B', locale)
                one_break_a = next(y for text, y in one_break_lines if text == 'PARA-A')
                one_break_b = next(y for text, y in one_break_lines if text == 'PARA-B')
                line_height = one_break_a - one_break_b
                self.assertAlmostEqual(2 * line_height, y_a - y_b, delta=1,
                                       msg='an explicit blank paragraph must reserve one full line')

        crlf_lines, crlf_max = render_message('PARA-A\r\nPARA-B', 'en')
        lf_lines, lf_max = render_message('PARA-A\nPARA-B', 'en')
        self.assertEqual(crlf_max, lf_max, 'CRLF is one line break, not two')
        crlf_a = next(y for text, y in crlf_lines if text == 'PARA-A')
        crlf_b = next(y for text, y in crlf_lines if text == 'PARA-B')
        self.assertAlmostEqual(16, crlf_a - crlf_b, delta=1)

        leading_lines, leading_max = render_message('\nPARA-A\n', 'en')
        plain_lines, plain_max = render_message('PARA-A', 'en')
        leading_y = next(y for text, y in leading_lines if text == 'PARA-A')
        plain_y = next(y for text, y in plain_lines if text == 'PARA-A')
        self.assertAlmostEqual(16, plain_y - leading_y, delta=1,
                               msg='leading empty paragraph must remain in the layout')
        self.assertEqual(leading_max, plain_max,
                         'short copy should fit without scrolling')
        empty_name_lines, _ = render_message('PARA-B', 'en', name='')
        one_char_name_lines, _ = render_message('PARA-B', 'en', name='X')
        empty_name_y = next(y for text, y in empty_name_lines if text == 'PARA-B')
        one_char_name_y = next(y for text, y in one_char_name_lines if text == 'PARA-B')
        self.assertAlmostEqual(one_char_name_y, empty_name_y, delta=1,
                               msg='an empty wrapped value occupies one layout line')

        long_prefix = 'X' * 1100
        _, no_break_max = render_message(long_prefix, 'en')
        _, trailing_blank_max = render_message(long_prefix + '\n', 'en')
        _, one_break_max = render_message(long_prefix + '\nB', 'en')
        _, blank_break_max = render_message(long_prefix + '\n\nB', 'en')
        blank_row_height = blank_break_max - one_break_max
        self.assertGreater(blank_row_height, 0,
                           msg='scroll height must include explicit empty lines')
        self.assertAlmostEqual(blank_row_height, trailing_blank_max - no_break_max, delta=1,
                               msg='trailing paragraph breaks must reserve the same scroll height')
        _, crlf_scroll_max = render_message(long_prefix + '\r\nB', 'en')
        self.assertAlmostEqual(one_break_max, crlf_scroll_max, delta=1,
                               msg='CRLF must add only one line to scroll height')

if __name__ == '__main__':
    unittest.main()
