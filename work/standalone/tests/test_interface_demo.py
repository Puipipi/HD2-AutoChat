"""Offline contract tests for the independently packaged API example."""
import importlib.util
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
import zipfile

from lupa.luajit21 import LuaRuntime

ROOT = Path(__file__).resolve().parents[3]
DEMO = ROOT / 'src/examples/interface_demo.lua'
PLUGIN_UI = ROOT / 'src/plugin_ui.lua'
BUILDER = ROOT / 'tools/build_interface_demo.py'


class InterfaceDemoTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.wrap = self.lua.eval('function(f) return function(...) return f(...) end end')
        self.sent = []
        self.specs = {}
        self.language = 'zh'
        self.settings_role = 'client'
        self.settings_enabled = False
        self.lua.globals().capture_plugin = self._register
        self.lua.execute('HD2AutoChatPlugins = {register=function(spec) return capture_plugin(spec) end}')
        self.spec = self.lua.execute(DEMO.read_text(encoding='utf-8'))

    def _register(self, spec):
        self.specs[str(spec.id)] = spec
        return spec

    def _api(self):
        settings = self.lua.table_from({
            'enabled': self.settings_enabled, 'cooldown': 7, 'output': 'local', 'role': self.settings_role,
            'language': self.language,
        })

        def send(text, creator=None, options=None):
            self.sent.append((str(text), creator, options))
            return True, 2

        self.lua.globals().demo_send = send
        self.lua.globals().demo_settings = lambda: settings
        return self.lua.execute('return {version=2, api_version=2, api_revision=4, '
                                'capabilities={independent_send=true,settings=true,plugin_presets=true}, '
                                'send=function(...) return demo_send(...) end, '
                                'settings=function() return demo_settings() end}')

    def _draw(self, ctx=None):
        calls = {'text': [], 'buttons': [], 'lines': [], 'icons': []}
        self.lua.globals().demo_text = lambda *args: calls['text'].append(args)
        self.lua.globals().demo_button = lambda key, label, *args: calls['buttons'].append((str(key), str(label)))
        self.lua.globals().demo_line = lambda *args: calls['lines'].append(args)
        self.lua.globals().demo_icon = lambda *args: calls['icons'].append(args)
        self.lua.globals().demo_language = self.language
        ui = self.lua.execute('return {text=function(...) return demo_text(...) end, '
                              'button=function(...) return demo_button(...) end, '
                              'line=function(...) return demo_line(...) end, '
                              'icon=function(...) return demo_icon(...) end, '
                              'language=demo_language, palette={LINE2=1}}')
        if ctx is None:
            ctx = self.lua.table_from({'language': self.language})
        self.spec.draw(ui, self.lua.table() if ctx is None else ctx, self._api())
        return calls

    def test_locale_switch_updates_existing_demo_and_english_template_send(self):
        self.assertEqual(str(self.spec.name), '接口示例')
        self.assertEqual(str(self.spec.name_en), 'API Demo')
        self.assertIsNone(self.spec.on_event)
        zh = self._draw()
        self.assertIn('跨模组发送接口示例（API v2 revision 4）',
                      [str(args[0]) for args in zh['text']])
        self.assertEqual(self.sent, [])

        api = self._api()
        self.spec.on_click('mode', api)
        self.spec.on_click('cooldown', api)
        self.spec.on_click('output', api)

        self.language = 'en'
        en = self._draw()
        en_text = '\n'.join(str(args[0]) for args in en['text'])
        en_buttons = '\n'.join(label for _, label in en['buttons'])
        self.assertIn('Cross-mod send API demo (API v2 revision 4)', en_text)
        self.assertIn('Host settings: off / cooldown 7s / local / client', en_text)
        self.assertIn('Mode: independent; independent send: on; cooldown: 5s; output: local', en_text)
        self.assertIn('Send mode: independent', en_buttons)
        self.assertEqual(self.sent, [], 'language redraw must not send')
        self.assertEqual(len(self.specs), 1, 'language redraw must not register again')

        self.spec.on_click('template', api)
        self.spec.on_click('send', api)
        self.assertEqual(self.sent[-1][0], 'AutoChat API demo: custom message Beta')
        self.assertEqual(self.sent[-1][2].policy, 'independent')
        self.assertEqual(self.sent[-1][2].cooldown, 5)
        self.assertEqual(self.sent[-1][2].output, 'local')

        self.spec.on_click('sample', api)
        self.assertEqual(self.sent[-1][0], 'AutoChat API demo: local sample event #1 (Map marker)')
        after_send = self._draw()
        self.assertIn('Sent', [str(args[0]) for args in after_send['text']])
        self.assertEqual(len(self.specs), 1)

    def test_draw_refreshes_host_settings_snapshot_without_a_click(self):
        self.settings_enabled = True
        first = self._draw()
        first_text = '\n'.join(str(args[0]) for args in first['text'])
        self.assertIn('主设置：开 / 间隔 7秒 / 仅自己 / 客机', first_text)

        self.settings_enabled = False
        second = self._draw()
        second_text = '\n'.join(str(args[0]) for args in second['text'])
        self.assertIn('主设置：关 / 间隔 7秒 / 仅自己 / 客机', second_text)
        self.assertEqual(self.sent, [], 'drawing a refreshed snapshot must not send')
        self.assertEqual(len(self.specs), 1, 'redrawing must not register the demo again')

    def test_load_is_passive_and_demo_exposes_manual_controls_and_settings(self):
        self.assertEqual(self.spec.id, 'auto_chat_demo')
        self.assertIsNone(self.spec.on_event, 'demo must not subscribe to live game events')
        calls = self._draw()
        self.assertEqual(self.sent, [], 'loading/drawing must never send')
        self.assertEqual({key for key, _ in calls['buttons']},
                         {'mode', 'enabled', 'cooldown', 'output', 'template', 'send', 'sample'})
        text_blob = '\n'.join(str(args[0]) for args in calls['text'])
        for expected in ('关', '7', '仅自己', '客机'):
            self.assertIn(expected, text_blob)
        self.assertTrue(calls['lines'], 'demo should exercise the line drawing facade')
        self.assertFalse(calls['icons'], 'missing loaded icon should not call the facade')
        self.assertIn('图标', text_blob, 'missing loaded icon should explain why it is absent')

    def test_independent_mode_options_and_inherit_mode(self):
        api = self._api()
        self.spec.on_click('mode', api)
        self.spec.on_click('enabled', api)
        disabled, _ = self.spec.on_click('send', api)
        self.assertFalse(disabled)
        self.assertEqual(self.sent, [], 'disabled demo must not call host send')
        self.spec.on_click('enabled', api)
        self.spec.on_click('cooldown', api)
        self.spec.on_click('output', api)
        self.spec.on_click('send', api)
        text, creator, options = self.sent[-1]
        self.assertEqual(text, 'AutoChat 接口示例：自定义消息 Alpha')
        self.assertIsNone(creator)
        self.assertEqual(options.policy, 'independent')
        self.assertTrue(options.enabled)
        self.assertEqual(options.cooldown, 5)
        self.assertEqual(options.cooldown_key, 'interface_demo')
        self.assertEqual(options.output, 'local')
        self.assertTrue(options.allow_solo)

        self.spec.on_click('mode', api)
        self.spec.on_click('send', api)
        self.assertEqual(len(self.sent[-1]), 3)
        self.assertIsNone(self.sent[-1][2], 'inherit path must use backwards-compatible default send')

    def test_plugin_preset_hooks_roundtrip_only_durable_demo_options_by_role(self):
        self.assertIsNotNone(self.spec.preset)
        self.assertTrue(self.spec.preset.capture)
        self.assertTrue(self.spec.preset.validate)
        self.assertTrue(self.spec.preset.apply)
        self.assertTrue(self.spec.preset.restore)
        self.settings_enabled = True
        self.settings_role = 'host'
        api = self._api()

        a = self.spec.preset.capture('host')
        self.spec.on_click('mode', api)
        self.spec.on_click('enabled', api)
        self.spec.on_click('cooldown', api)
        self.spec.on_click('output', api)
        self.spec.on_click('template', api)
        b = self.spec.preset.capture('host')
        self.assertNotEqual(a, b)

        self.assertTrue(self.spec.preset.validate(a, 'host'))
        self.assertFalse(self.spec.preset.validate(a + 'junk', 'host')[0])
        self.assertFalse(self.spec.preset.validate(a, 'other')[0])
        self.assertTrue(self.spec.preset.apply(a, 'host'))
        after_a = self._draw()
        text_a = '\n'.join(str(args[0]) for args in after_a['text'])
        buttons_a = '\n'.join(label for _, label in after_a['buttons'])
        self.assertIn('模式：继承主设置；独立发送：开；冷却：0秒；输出：继承主设置', text_a)
        self.assertIn('消息预览：AutoChat 接口示例：自定义消息 Alpha', text_a)
        self.assertIn('独立冷却：0秒', buttons_a)
        self.assertEqual(self.sent, [], 'preset callbacks must never send')

        self.assertTrue(self.spec.preset.apply(b, 'host'))
        after_b = self._draw()
        text_b = '\n'.join(str(args[0]) for args in after_b['text'])
        self.assertIn('模式：独立；独立发送：关；冷却：5秒；输出：仅自己', text_b)
        self.assertIn('消息预览：AutoChat 接口示例：自定义消息 Beta', text_b)
        self.assertEqual(self.sent, [], 'applying addon state must not send')

        client = self.spec.preset.capture('client')
        self.assertTrue(self.spec.preset.validate(client, 'client'))
        self.assertTrue(self.spec.preset.apply(a, 'client'))
        self.assertEqual(self.spec.preset.capture('client'), a)
        self.assertEqual(self.spec.preset.capture('host'), b,
                         'applying client state must not alter host state')

    def test_sample_preview_is_manual_and_icon_only_uses_host_loaded_resource(self):
        api = self._api()
        self.spec.on_click('sample', api)
        self.assertEqual(len(self.sent), 1)
        sample = self.sent[-1][0]
        self.assertIn('本地示例事件 #1', sample)
        self.spec.on_click('send', api)
        self.assertEqual(self.sent[-1][0], sample)

        ctx = self.lua.table_from({'loaded_icon': '0123456789ABCDEF'})
        calls = self._draw(ctx)
        self.assertEqual(len(calls['icons']), 1)
        self.assertEqual(str(calls['icons'][0][0]), '0123456789ABCDEF')

    def test_demo_draws_through_real_plugin_ui_facade_above_panel(self):
        calls = []
        def record(name):
            return self.wrap(lambda *args: calls.append((name, args)) or True)

        palette = self.lua.table_from({'TEXT': 'text', 'LINE2': 'line2', 'PANEL': 'panel',
                                       'YELLOW': 'yellow', 'ROW_HI': 'hover', 'INK': 'ink',
                                       'DIM': 'dim'})
        ux = self.lua.table_from({
            'text': record('text'), 'rect': record('rect'), 'border': record('border'),
            'region': record('region'), 'palette': palette,
        })
        ctx = self.lua.table_from({'id': 'auto_chat_demo', 'w': 1000, 'h': 990,
                                   'content_w': 960, 'content_h': 800,
                                   'language': 'en', 'loaded_icon': '0123456789ABCDEF'})
        image_draw = self.wrap(lambda *args: calls.append(('image', args)) or True)
        factory = self.lua.execute(PLUGIN_UI.read_text(encoding='utf-8'))
        ui = factory(self.lua.table_from({'UX': ux, 'context': ctx,
                                          'draw_image': image_draw}))
        self.assertEqual(str(ui.language), 'en')
        self.spec.draw(ui, ctx, self._api())
        self.assertEqual(calls[0][0], 'text')
        self.assertEqual(calls[0][1][0], 'Cross-mod send API demo (API v2 revision 4)')

        line_rects = [args for name, args in calls if name == 'rect' and args[-1] == 953]
        self.assertEqual(len(line_rects), 1, 'horizontal line should be one rectangle')
        self.assertEqual(line_rects[0][4], 'line2')
        self.assertGreater(line_rects[0][5], 951, 'line must render over panel z=951')
        images = [args for name, args in calls if name == 'image']
        self.assertEqual(len(images), 1)
        self.assertEqual(images[0][0], '0123456789ABCDEF')

    def test_bundle_is_valid_standalone_087_addon_with_api_docs(self):
        spec = importlib.util.spec_from_file_location('build_interface_demo', BUILDER)
        builder = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(builder)
        with tempfile.TemporaryDirectory() as directory:
            output = builder.build(Path(directory) / 'demo.zip')
            with zipfile.ZipFile(output) as package:
                self.assertIsNone(package.testzip())
                self.assertEqual(set(package.namelist()), {
                    'Addon/9ba626afa44a3aa3.patch_0',
                    'Addon/9ba626afa44a3aa3.patch_0.stream',
                    'Addon/9ba626afa44a3aa3.patch_0.gpu_resources',
                    'manifest.json', 'README.txt',
                    'Docs/PLUGIN-API.md', 'Docs/INTERFACE-DEMO.md'})
                manifest = json.loads(package.read('manifest.json'))
                self.assertEqual(manifest['Guid'], builder.GUID)
                self.assertEqual(manifest['Name'], 'AutoChat 接口示例')
                addon_archive = next(name for name in package.namelist()
                                     if name.startswith('Addon/')
                                     and not name.endswith(('.stream', '.gpu_resources')))
                readme = package.read('README.txt').decode('utf-8')
                self.assertIn('1.0.0', readme)
                self.assertTrue(package.read(addon_archive))
                root = Path(__file__).resolve().parents[3]
                self.assertEqual(package.read('Docs/PLUGIN-API.md'),
                                 (root / 'docs/PLUGIN-API.md').read_bytes())
                self.assertEqual(package.read('Docs/INTERFACE-DEMO.md'),
                                 (root / 'docs/INTERFACE-DEMO.md').read_bytes())
            sidecar = output.with_suffix(output.suffix + '.sha256').read_text(encoding='ascii')
            digest = hashlib.sha256(output.read_bytes()).hexdigest()
            self.assertEqual(sidecar, digest + '  ' + output.name + '\n')


if __name__ == '__main__':
    unittest.main()
