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


if __name__ == '__main__':
    unittest.main()
