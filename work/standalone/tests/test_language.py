"""Pure language selection, fixed phrases and exact stock-template localization."""
from pathlib import Path
import unittest

from lupa.luajit21 import LuaRuntime

ROOT = Path(__file__).resolve().parents[5]
SOURCE = ROOT / 'mods/auto-chat/src/language.lua'


class LanguageTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(encoding=None, unpack_returned_tuples=True)
        self.assertTrue(SOURCE.exists(), 'language module is missing')
        build = self.lua.execute(SOURCE.read_bytes())
        self.locale, self.dirty = None, []
        self.module = build(self.lua.table_from({
            b'read_game': lambda: self.locale,
            b'dirty': lambda: self.dirty.append(True),
        }))

    def test_auto_switches_english_and_chinese_and_invalid_languages_fall_back_to_english(self):
        self.locale = b'zh'
        self.assertEqual(self.module[b'update'](b'auto', 1), b'zh')
        self.locale = b'en'
        self.assertEqual(self.module[b'update'](b'auto', 121), b'en')
        self.locale = b'fr'
        self.assertEqual(self.module[b'update'](b'auto', 241), b'en')
        self.assertEqual(self.dirty, [True, True])

    def test_overrides_and_failed_reads_preserve_last_known_language(self):
        self.locale = b'zh'
        self.assertEqual(self.module[b'update'](b'auto', 1), b'zh')
        self.assertEqual(self.module[b'update'](b'en', 2), b'en')
        self.locale = None
        self.assertEqual(self.module[b'update'](b'auto', 3), b'en')
        self.assertEqual(self.module[b'update'](b'zh', 4), b'zh')
        self.assertEqual(self.module[b'update'](b'auto', 5), b'zh')

    def test_auto_reads_are_throttled_and_changes_dirty_the_panel(self):
        reads = []
        def read_game():
            reads.append(True)
            return b'zh'
        build = self.lua.execute(SOURCE.read_bytes())
        module = build(self.lua.table_from({b'read_game': read_game,
                                            b'dirty': lambda: self.dirty.append(True)}))
        module[b'update'](b'auto', 0)
        module[b'update'](b'auto', 119)
        self.assertEqual(len(reads), 1)
        module[b'update'](b'auto', 120)
        self.assertEqual(len(reads), 2)
        self.assertEqual(self.dirty, [True])

    def test_text_dictionary_and_stock_templates_leave_custom_data_untouched(self):
        self.locale = b'en'
        self.module[b'update'](b'auto', 0)
        self.assertEqual(self.module[b'phrase'](b'category.stratagem'), b'STRATAGEM')
        self.assertEqual(self.module[b'phrase'](b'tab.special_targets'), b'SPECIAL TARGETS')
        self.assertEqual(self.module[b'phrase'](b'toggle.mission_items'), b'MISSION ITEM ALERTS')
        self.assertEqual(self.module[b'stock_template']('标记了{目标}（{类别}）'.encode()),
                         'Marked {目标} ({类别})'.encode())
        custom = '自定义：{目标}，队员提醒'.encode()
        self.assertEqual(self.module[b'stock_template'](custom), custom)
        self.assertEqual(self.module[b'text']('中文'.encode(), b'ENGLISH'), b'ENGLISH')
        self.module[b'update'](b'zh', 1)
        self.assertEqual(self.module[b'phrase'](b'category.poi'), '特殊目标'.encode())
        self.assertEqual(self.module[b'phrase'](b'label.cooldown'), '冷却（秒）'.encode())
        self.assertEqual(self.module[b'stock_template']('Marked {目标} ({类别})'.encode()),
                         '标记了{目标}（{类别}）'.encode())
        self.assertEqual(self.module[b'stock_template'](b'HELLO FROM AUTOCHAT'),
                         '自动聊天测试消息'.encode())

    def test_status_resolves_known_ui_messages_and_preserves_dynamic_suffixes(self):
        status = self.module[b'status']
        self.assertEqual(status('等待战备目录'.encode()), b'Waiting for stratagem catalog')
        self.assertEqual(status('战备目录读取就绪（149）'.encode()),
                         b'Stratagem catalog ready (149)')
        self.assertEqual(status('预设应用失败：预设版本无效'.encode()),
                         b'Preset apply failed: Preset version is invalid')
        self.assertEqual(status('预设库不可用：读取失败'.encode()),
                         'Preset library unavailable: 读取失败'.encode())

    def test_status_does_not_translate_custom_names_or_unknown_messages(self):
        status = self.module[b'status']
        custom = '我的中文预设名'.encode()
        unknown = '自定义操作失败：请联系小队'.encode()
        self.assertEqual(status(custom), custom)
        self.assertEqual(status(unknown), unknown)

    def test_chinese_status_is_returned_byte_for_byte(self):
        self.module[b'update'](b'zh', 1)
        status = self.module[b'status']
        value = '战备目录读取就绪（149）'.encode()
        self.assertEqual(status(value), value)


if __name__ == '__main__':
    unittest.main()
