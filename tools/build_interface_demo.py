"""Build the independently loaded AutoChat API example, without installing it."""
from pathlib import Path
import sys
import zipfile

from lupa.luajit21 import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'work/standalone/vendor/bingus'))
from build_addon import build_addon

RESOURCE = 'mods/codex/auto_chat_demo'
GUID = 'a1000000-0000-4000-8000-000000000023'


def build(output=None):
    source = (ROOT / 'src/examples/interface_demo.lua').read_text(encoding='utf-8')
    LuaRuntime().compile(source)
    output = Path(output) if output else ROOT / 'dist/AutoChat-Interface-Demo-0.7.0.zip'
    build_addon(RESOURCE, source.encode('utf-8'), GUID, output, 'AutoChat 接口示例')
    with zipfile.ZipFile(output, 'a', compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr('README.txt',
            'AutoChat 接口示例 0.7.0\r\n'
            '需要 Bingus Shared Loader v15+ 和 AutoChat 0.7.0。独立启用并部署此包。\r\n'
            'K → 接口示例：开启标记计数，或点击发送测试消息。加载时不会自动发送。\r\n'
            '测试消息仍受 AutoChat 总开关、主客机范围、无人房间和自动消息最短间隔限制。\r\n'
            '默认计数关闭；本示例状态仅保留到退出游戏。\r\n'
            '资源：' + RESOURCE + '\r\nGUID：' + GUID + '\r\n')
    with zipfile.ZipFile(output) as archive:
        assert archive.testzip() is None
        assert len(archive.namelist()) == 5
    print(output)
    return output


if __name__ == '__main__':
    build()
