"""Render real Lua draw commands through the offline harness for layout inspection.

This is an offline layout preview, not a capture of the game's native font renderer.
"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "work/standalone/tests"))
from test_auto_chat_probe import fresh_image, SOURCE


def render(output, populated=False, automation=False, view=None, plugin=False, profile=None):
    lua, h = fresh_image(font_ids=True)
    mod = h.load(SOURCE)
    if plugin:
        lua.execute((ROOT / 'src/examples/interface_demo.lua').read_text(encoding='utf-8'))
        mod.debug_panel()['active_plugin'] = 'auto_chat_demo'
    operations = {}
    fonts = {}
    font_path = Path("C:/Windows/Fonts/msyh.ttc")

    def font(size):
        size = max(6, int(size))
        if size not in fonts:
            fonts[size] = ImageFont.truetype(str(font_path), size)
        return fonts[size]

    def rect(gui, pos, size, colour):
        operations.setdefault(gui["id"], []).append((pos["z"], "rect", pos, size, colour))

    def text(gui, value, face, size, material, pos, colour):
        operations.setdefault(gui["id"], []).append((pos["z"], "text", pos, (value, size), colour))

    def extents(gui, value, face, size):
        width = font(size).getlength(str(value))
        return lua.table_from({"x": 0}), lua.table_from({"x": width})

    engine = lua.globals().stingray
    engine.Gui.rect, engine.Gui.text, engine.Gui.text_extents = rect, text, extents
    # The resolver deliberately requires Lua functions for engine primitives.
    lua.execute("""
        local rect, text, extents = stingray.Gui.rect, stingray.Gui.text, stingray.Gui.text_extents
        stingray.Gui.rect = function(...) return rect(...) end
        stingray.Gui.text = function(...) return text(...) end
        stingray.Gui.text_extents = function(...) return extents(...) end
    """)
    if populated:
        mod.add_task("小队集合提醒", "repeat", "30", "请在撤离点集合。", 10000000000)
        mod.add_task("出发倒计时", "once", "120", "两分钟后出发！", 10000000000)
        mod.add_task("每日问候", "daily", "21:30", "晚上好，超级地球的战士们。", 10000000000)
    mod.debug_set_open(True)
    if automation:
        mod.debug_panel()['settings_view'] = 'automation'
    if view:
        mod.debug_panel()['settings_view'] = view
    if profile:
        mod.debug_panel()['profile'] = profile
    lua.execute("for i=1,601 do update() end")
    if mod.draw_errors or mod.panel_errors:
        raise RuntimeError(str(mod.debug_panel()["hint"]) + str(mod.draw_error_text))
    canvas = Image.new("RGB", (1920, 1080), (29, 33, 38))
    draw = ImageDraw.Draw(canvas)
    gui = mod.debug_panel()["gui"]["id"]
    for _, kind, pos, data, c in sorted(operations[gui], key=lambda x: x[0]):
        colour = (int(c["r"]), int(c["g"]), int(c["b"]))
        x = int(pos["x"])
        if kind == "rect":
            y = int(1080 - pos["y"] - data["y"])
            draw.rectangle((x, y, x + int(data["x"]) - 1, y + int(data["y"]) - 1), fill=colour)
        else:
            value, size = data
            y = int(1080 - pos["y"] - size * 0.8)
            draw.text((x, y), str(value), font=font(size), fill=colour, anchor="lt")
    geo = mod.debug_geometry(1920, 1080)
    left, top = int(geo["x"]), int(geo["y"])
    canvas = canvas.crop((left - 8, top - 8, left + int(geo["w"]) + 8, top + int(geo["h"]) + 8))
    output.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(output)
    print(output)


if __name__ == "__main__":
    render(ROOT / "docs/settings-preview.png", populated=True)
    render(ROOT / "docs/automation-preview.png", populated=True, automation=True)

    render(ROOT / "docs/ping-preview.png", populated=True, view="pings")
    render(ROOT / "docs/plugin-demo-preview.png", plugin=True)
    render(ROOT / "docs/client-profile-preview.png", automation=True, profile='client')
