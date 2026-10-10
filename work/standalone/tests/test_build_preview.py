import ast
from pathlib import Path
import unittest


BUILDER = Path(__file__).resolve().parents[1] / 'build_mod.py'


def load_preview_helpers():
    tree = ast.parse(BUILDER.read_text(encoding='utf-8'))
    selected = [node for node in tree.body
                if isinstance(node, ast.FunctionDef)
                and node.name in {'apply_preview_locale', 'package_filename'}]
    marker = next(node for node in tree.body
                  if isinstance(node, ast.Assign)
                  and any(isinstance(target, ast.Name) and target.id == 'PREVIEW_MARKER'
                          for target in node.targets))
    namespace = {}
    exec(compile(ast.Module(body=[marker] + selected, type_ignores=[]),
                 str(BUILDER), 'exec'), namespace)
    return namespace


HELPERS = load_preview_helpers()


class BuildPreviewTests(unittest.TestCase):
    def test_default_source_and_archive_name_remain_unchanged(self):
        source = "local M = {}\nM.ui_preview_language = nil " + HELPERS['PREVIEW_MARKER'] + "\n"
        self.assertEqual(HELPERS['apply_preview_locale'](source, None), source)
        self.assertEqual(HELPERS['package_filename']('AutoChat', '1.0.0'),
                         'AutoChat-1.0.0.zip')

    def test_english_preview_changes_only_unique_marker_line(self):
        marker = HELPERS['PREVIEW_MARKER']
        source = "before\nM.ui_preview_language = nil " + marker + "\nafter\n"
        expected = "before\nM.ui_preview_language = 'en' " + marker + "\nafter\n"
        self.assertEqual(HELPERS['apply_preview_locale'](source, 'en'), expected)
        self.assertEqual(HELPERS['package_filename']('AutoChat', '1.0.0', 'en'),
                         'AutoChat-1.0.0-EnglishUI.zip')

    def test_missing_or_duplicate_marker_is_rejected(self):
        apply_locale = HELPERS['apply_preview_locale']
        with self.assertRaisesRegex(ValueError, 'exactly one'):
            apply_locale('no marker', 'en')
        marker = HELPERS['PREVIEW_MARKER']
        line = 'M.ui_preview_language = nil ' + marker
        with self.assertRaisesRegex(ValueError, 'exactly one'):
            apply_locale(line + '\n' + line, 'en')


if __name__ == '__main__':
    unittest.main()
