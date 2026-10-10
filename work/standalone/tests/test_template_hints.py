"""Render the template hint lines in every relevant panel and UI locale."""
import unittest

from test_auto_chat_probe import SOURCE, fresh_image


PLAYER_PAIRS = (('{玩家名}', '{player_name}'), ('{缩写}', '{abbr}'), ('{编号}', '{slot}'))
EVENT_PAIRS = (
    ('{目标}', '{target}'), ('{战备}', '{stratagem}'), ('{类别}', '{category}'),
    ('{动作}', '{action}'), ('{任务名}', '{objective}'),
    ('{任务类型}', '{objective_type}'), ('{位置}', '{position}'),
)


class TemplateHintRenderingTests(unittest.TestCase):
    def setUp(self):
        self.lua, self.h = fresh_image(font_ids=True)
        self.lua.execute(r'''
            test_drawn_texts={}
            local original_text=stingray.Gui.text
            stingray.Gui.text=function(gui,value,font,size,material,position,color)
                test_drawn_texts[#test_drawn_texts+1]={text=tostring(value),
                    x=position.x,y=position.y,size=size}
                return original_text(gui,value,font,size,material,position,color)
            end
            -- The fixture's stock extents count UTF-8 bytes. Count code points here so
            -- the actual panel text path can size Chinese and English labels fairly.
            stingray.Gui.text_extents=function(gui,value,font,size)
                local count=0
                for i=1,#tostring(value) do
                    local byte=tostring(value):byte(i)
                    if byte<128 or byte>=192 then count=count+1 end
                end
                return {x=0},{x=count*size*0.55}
            end
        ''')
        self.mod = self.h.load(SOURCE)
        self.mod.debug_set_open(True)
        self._run(700)
        self.lua.execute(r'''
            test_locale='en'
            local language=HD2AutoChat.debug_language()
            local original_update=language.update
            language.update=function(option,frame)
                if option=='auto' then return original_update(test_locale,frame) end
                return original_update(option,frame)
            end
        ''')

    def _run(self, frames):
        for _ in range(frames):
            self.lua.eval('_G.update()')

    def draw_page(self, view, locale):
        panel = self.mod.debug_panel()
        panel.rule_view = 'enemy' if view == 'rules' else None
        panel.preset_view = None
        panel.active_plugin = None
        panel.settings_view = {'pings': 'pings', 'welcome': 'automation',
                               'timer': 'tasks', 'rules': 'automation'}[view]
        self.lua.globals().test_locale = locale
        self.mod.debug_language().update(locale, self.mod.frames)
        self.lua.globals().test_drawn_texts = self.lua.table()
        self._run(1)
        texts = self.lua.globals().test_drawn_texts
        return [texts[i] for i in range(1, len(texts) + 1)]

    @staticmethod
    def text_of(rows):
        return '\n'.join(str(row['text']) for row in rows)

    def assert_pairs_visible(self, rendered, pairs):
        for chinese, english in pairs:
            self.assertIn(chinese, rendered)
            self.assertIn(english, rendered)

    def assert_drawn_lines_fit(self, rows):
        self.assertTrue(rows, 'the selected view must reach the native text renderer')
        hint_rows = []
        for row in rows:
            value = str(row['text'])
            size = float(row['size'])
            x, y = float(row['x']), float(row['y'])
            width = len(value) * size * 0.55
            top = 1080 - y - size * 0.8
            bottom = top + size
            self.assertGreaterEqual(x, 0)
            self.assertLessEqual(x + width, 1920,
                                 'drawn text runs beyond the right edge: ' + value)
            self.assertGreaterEqual(top, 0,
                                    'drawn text runs above the screen: ' + value)
            self.assertLessEqual(bottom, 1080,
                                 'drawn text runs below the screen: ' + value)
            if any(token in value for token in ('{玩家名}', '{player_name}', '{目标}',
                                                '{target}', '{任务名}', '{objective}')):
                self.assertGreaterEqual(size, 12,
                                        'template hints must remain readable: ' + value)
            if any(chinese in value for chinese, _ in PLAYER_PAIRS + EVENT_PAIRS):
                hint_rows.append((row, value, width))
                self.assertNotIn('..', value,
                                 'template hint was clipped by its panel width: ' + value)
                self.assertLessEqual(width, 474,
                                     'template hint exceeds the panel column: ' + value)
        ordered = sorted(hint_rows, key=lambda item: float(item[0]['y']))
        for (previous, previous_text, _), (current, current_text, _) in zip(ordered, ordered[1:]):
            self.assertGreaterEqual(abs(float(current['y']) - float(previous['y'])), 12,
                                    'template hint rows overlap: ' + previous_text + ' / ' + current_text)
        if any('{玩家名}' in value for _, value, _ in hint_rows):
            footer = next((row for row in rows if 'ENTER SAVE' in str(row['text'])
                           or 'Enter 保存' in str(row['text'])), None)
            if footer is not None:
                last_hint = min(hint_rows, key=lambda item: float(item[0]['y']))[0]
                self.assertGreaterEqual(abs(float(last_hint['y']) - float(footer['y'])), 12,
                                        'rule template hints overlap the save footer')

    def test_bilingual_tokens_render_in_all_four_views_and_both_locales(self):
        for locale in ('zh', 'en'):
            for view in ('rules', 'pings', 'welcome', 'timer'):
                with self.subTest(locale=locale, view=view):
                    rows = self.draw_page(view, locale)
                    rendered = self.text_of(rows)
                    self.assert_drawn_lines_fit(rows)
                    self.assert_pairs_visible(rendered, PLAYER_PAIRS)
                    if view in ('rules', 'pings'):
                        self.assert_pairs_visible(rendered, EVENT_PAIRS)


if __name__ == '__main__':
    unittest.main()
