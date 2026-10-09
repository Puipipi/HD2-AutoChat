"""Safe plugin drawing facade tests at the host graphics boundary."""
from pathlib import Path
import unittest

from lupa.luajit21 import LuaRuntime

SOURCE = Path(__file__).resolve().parents[3] / 'src' / 'plugin_ui.lua'


class PluginUiTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(SOURCE.exists(), 'plugin UI facade is not implemented')
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.calls = []
        self.wrap = self.lua.eval('function(f) return function(...) return f(...) end end')
        self.palette = self.lua.table_from({'TEXT': 'text-colour', 'PANEL': 'panel-colour',
                                            'LINE2': 'border-colour', 'YELLOW': 'active-colour',
                                            'ROW_HI': 'hover-colour', 'INK': 'ink-colour',
                                            'DIM': 'dim-colour'})
        self.ux = self.lua.table_from({
            'text': self.wrap(lambda *a: self._record('text', *a)),
            'rect': self.wrap(lambda *a: self._record('rect', *a)),
            'border': self.wrap(lambda *a: self._record('border', *a)),
            'region': self.wrap(lambda *a: self._record('region', *a)),
            'colour': self.wrap(lambda *a: self._record('colour', *a)),
            'palette': self.palette,
            's': 0.8,
        })
        builder = self.lua.execute(SOURCE.read_text(encoding='utf-8'))
        self.factory = builder

    def _record(self, name, *args):
        self.calls.append((name, args))
        return True

    def make_ui(self, draw_image=None, context=None):
        context = context or {'id': 'sample', 'ox': 20, 'oy': 160, 'w': 1000,
                              'h': 990, 'content_w': 960, 'content_h': 800,
                              'scale': 0.8, 'hover': None, 'language': 'zh'}
        return self.factory(self.lua.table_from({
            'UX': self.ux, 'context': self.lua.table_from(context),
            'note': self.wrap(lambda *a: self._record('note', *a)),
            'draw_image': self.wrap(draw_image) if draw_image else None,
        }))

    def test_legacy_helpers_keep_body_offset_palette_and_button_hit_key(self):
        ui = self.make_ui()
        self.assertEqual(ui.language, 'zh')
        self.assertEqual(self.make_ui(context={'id': 'sample', 'ox': 20, 'oy': 160,
            'w': 1000, 'h': 990, 'content_w': 960, 'content_h': 800,
            'scale': 0.8, 'hover': None, 'language': 'en'}).language, 'en')
        self.assertEqual(ui.text('title', 12, 18, 14, 'white', 300), True)
        ui.rect(4, 5, 20, 10, 'fill', 950)
        ui.border(4, 5, 20, 10, 'line', 951)
        ui.region('hit', 8, 9, 30, 20)
        self.assertTrue(ui.button('send', 'Send', 10, 12, 100, 32, True, False))
        self.assertTrue(self.lua.eval('function(a,b) return rawequal(a,b) end')(
            ui.palette, self.palette))
        self.assertEqual(ui.colour(1, 2, 3, 4), True)
        regions = [args for name, args in self.calls if name == 'region']
        self.assertEqual(regions[-2], ('plugin:sample:hit', 28, 169, 30, 20))
        self.assertEqual(regions[-1], ('plugin:sample:send', 30, 172, 100, 32))
        self.assertEqual(self.calls[0], ('text', ('title', 32, 178, 14, 'white', 300)))
        self.assertIn(('rect', (24, 165, 20, 10, 'fill', 950)), self.calls)
        self.assertIn(('border', (24, 165, 20, 10, 'line', 951)), self.calls)

    def test_image_and_icon_pass_only_resource_and_bounded_panel_geometry(self):
        images = []
        def draw_image(*args):
            images.append(args)
            return True
        ui = self.make_ui(draw_image=self.wrap(draw_image))
        self.assertTrue(ui.image('F96A659EBFFDFBE4', 10, 20, 64, 32, 'tint', 953))
        self.assertTrue(ui.icon('f96a659ebffdfbe4', 80, 20, 24))
        self.assertEqual(images[0], ('F96A659EBFFDFBE4', 30, 180, 64, 32, 'tint', 953))
        self.assertEqual(images[1][0:5], ('f96a659ebffdfbe4', 100, 180, 24, 24))
        self.assertEqual(len(images[0]), 7, 'no native gui/material handles cross the callback')

    def test_unavailable_material_returns_reason_without_native_draw(self):
        def unavailable(*args):
            return False, 'material_unavailable'
        ui = self.make_ui(draw_image=self.wrap(unavailable))
        result = ui.image('F96A659EBFFDFBE4', 1, 2, 20, 20)
        self.assertEqual(result, (False, 'material_unavailable'))

    def test_image_rejects_bad_resource_and_out_of_bounds_before_host_callback(self):
        images = []
        ui = self.make_ui(draw_image=self.wrap(lambda *args: images.append(args) or True))
        self.assertEqual(ui.image('not-a-resource', 1, 2, 20, 20), (False, 'invalid_resource'))
        self.assertEqual(ui.image('F96A659EBFFDFBE4', 950, 2, 20, 20), (False, 'out_of_bounds'))
        self.assertEqual(ui.image('F96A659EBFFDFBE4', 1, 2, float('nan'), 20),
                         (False, 'invalid_geometry'))
        self.assertEqual(ui.image('F96A659EBFFDFBE4', 1, 2, -1, 20),
                         (False, 'invalid_geometry'))
        self.assertEqual(images, [])

    def test_line_draws_bounded_rectangles_and_rejects_invalid_or_long_geometry(self):
        ui = self.make_ui()
        self.assertTrue(ui.line(10, 10, 30, 20, 'line-colour', 952, 2))
        lines = [args for name, args in self.calls if name == 'rect']
        self.assertGreater(len(lines), 1)
        self.assertTrue(all(len(args) == 6 and args[2] > 0 and args[3] > 0 for args in lines))
        self.assertEqual(ui.line(1, 1, 30, 20, 'line-colour', 952, float('inf')),
                         (False, 'invalid_geometry'))
        self.assertEqual(ui.line(1, 1, 1000, 20), (False, 'out_of_bounds'))
        self.assertEqual(ui.line(0, 1, 1, 1, 'line-colour', 952, -1),
                         (False, 'invalid_geometry'))

    def test_axis_aligned_lines_use_one_native_rectangle_and_diagonal_is_bounded(self):
        ui = self.make_ui()
        self.calls.clear()
        self.assertTrue(ui.line(10, 10, 410, 10, 'line-colour'))
        horizontal = [args for name, args in self.calls if name == 'rect']
        self.assertEqual(len(horizontal), 1)
        self.assertEqual(horizontal[0][2:4], (400, 1))

        self.calls.clear()
        self.assertTrue(ui.line(10, 10, 10, 410, 'line-colour'))
        vertical = [args for name, args in self.calls if name == 'rect']
        self.assertEqual(len(vertical), 1)
        self.assertEqual(vertical[0][2:4], (1, 400))

        self.calls.clear()
        self.assertTrue(ui.line(10, 10, 100, 100, 'line-colour', None, 2))
        diagonal = [args for name, args in self.calls if name == 'rect']
        self.assertGreater(len(diagonal), 1)
        self.assertLessEqual(len(diagonal), 512)

        self.calls.clear()
        self.assertTrue(ui.line(10, 10, 10, 10, 'line-colour'))
        zero_length = [args for name, args in self.calls if name == 'rect']
        self.assertEqual(len(zero_length), 1)

    def test_zero_length_line_drawn_rectangle_matches_bounds_validation(self):
        ui = self.make_ui()
        self.assertTrue(ui.line(959, 10, 959, 10, 'line-colour', None, 2))
        rectangles = [args for name, args in self.calls if name == 'rect']
        self.assertEqual(len(rectangles), 1)
        x, y, width, height = rectangles[0][:4]
        self.assertGreaterEqual(x, 20)
        self.assertGreaterEqual(y, 160)
        self.assertLessEqual(x + width, 20 + 960)
        self.assertLessEqual(y + height, 160 + 800)
        self.assertEqual((x, y, width, height), (978, 169, 2, 2))

    def test_utf8_text_estimate_counts_characters_and_image_preserves_reason(self):
        ui = self.make_ui()
        self.assertTrue(ui.text('样本箱', 933, 10, 14))
        self.assertEqual(self.calls[-1], ('text', ('样本箱', 953, 170, 14, None, 27)))

        self.calls.clear()
        self.assertTrue(ui.text('样本箱', 40, 10, 14, None, None, 'right'))
        self.assertEqual(self.calls[-1], ('text', ('样本箱', 60, 170, 14, None, 40, 'right')))

        self.calls.clear()
        self.assertTrue(ui.text('样本箱', 20, 10, 14, None, None, 'center'))
        self.assertEqual(self.calls[-1], ('text', ('样本箱', 40, 170, 14, None, 40, 'center')))

        self.calls.clear()
        self.assertTrue(ui.text('显式', 20, 20, 14, None, 180))
        self.assertEqual(self.calls[-1], ('text', ('显式', 40, 180, 14, None, 180)))

        ui = self.make_ui(draw_image=self.wrap(lambda *args: (False, 'not_loaded')))
        self.assertEqual(ui.image('F96A659EBFFDFBE4', 1, 1, 20, 20),
                         (False, 'not_loaded'))

    def test_text_and_legacy_shapes_reject_nan_infinity_negative_and_overflow(self):
        ui = self.make_ui()
        self.assertEqual(ui.text('bad', float('nan'), 1), (False, 'invalid_geometry'))
        self.assertEqual(ui.text('bad', 1, float('inf')), (False, 'invalid_geometry'))
        self.assertEqual(ui.text('bad', 1, 1, -4), (False, 'invalid_geometry'))
        self.assertEqual(ui.rect(1, 1, float('inf'), 5), (False, 'invalid_geometry'))
        self.assertEqual(ui.rect(1, 1, -2, 5), (False, 'invalid_geometry'))
        self.assertEqual(ui.rect(959, 1, 2, 5), (False, 'out_of_bounds'))
        self.assertEqual(ui.border(1, 1, 4, float('nan')), (False, 'invalid_geometry'))
        self.assertEqual(ui.region('bad', 1, 1, 4, 900), (False, 'out_of_bounds'))
        self.assertEqual(self.calls, [])


if __name__ == '__main__':
    unittest.main()
