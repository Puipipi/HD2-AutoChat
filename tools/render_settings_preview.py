"""Render real Lua draw commands through the offline harness for layout inspection.

This is an offline layout preview, not a capture of the game's native font renderer.
"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "work/standalone/tests"))
from test_auto_chat_probe import fresh_image, SOURCE


def render(output, populated=False, automation=False, view=None, plugin=False, profile=None, rule_view=None, preset=False):
    lua, h = fresh_image(font_ids=True)
    mod = h.load(SOURCE)
    if rule_view:
        # Representative rows for layout QA only; real names/icons come from the
        # guarded game catalog. No game icons are fabricated in this offline image.
        lua.execute('''local c=(...).debug_stratagem_catalog()
            local rows={
                {id=4119049995,name='500千克炸弹',debug_name='EAGLE.500KG',group='red',cooldown=15},
                {id=2902516083,name='轨道凝固汽油弹幕',debug_name='ORBITAL.NAPALM',group='red',cooldown=120},
                {id=867876502,name='重新补给',debug_name='CONSUMABLES.RESUPPLY',group='blue',cooldown=180,variant_ids={867876502,1295431756}},
                {id=3,name='机枪哨戒炮',debug_name='SENTRYS.MACHINEGUN',group='green',cooldown=180}}
            c.scan=function()return #rows,c.state.status end;c.list=function()return rows end;c.list_rules=c.list
            c.state.status='离线布局示例；游戏中读取名称和已加载图标'
        ''',mod)
    if preset:
        ok, _, preset_id = mod.debug_preset_library().save('小队欢迎', 'host')
        if not ok:
            raise RuntimeError('could not create preview preset')
        mod.debug_panel()['preset_view'] = True
        mod.debug_panel()['preset_selected'] = preset_id
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
    if rule_view:
        mod.debug_panel()['rule_view'] = rule_view
        if rule_view=='enemy':
            mod.debug_panel()['rule_selected']='flying_enemy'
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
    render(ROOT / "docs/stratagem-rules-preview.png", rule_view='stratagem')
    render(ROOT / "docs/enemy-rules-preview.png", rule_view='enemy')
    render(ROOT / "docs/preset-preview.png", preset=True)
