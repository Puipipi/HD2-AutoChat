"""Build the independently loaded AutoChat API example, without installing it."""
import hashlib
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
    output = Path(output) if output else ROOT / 'dist/AutoChat-Interface-Demo-1.0.0.zip'
    build_addon(RESOURCE, source.encode('utf-8'), GUID, output, 'AutoChat 接口示例')
    with zipfile.ZipFile(output, 'a', compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr('README.txt',
            'AutoChat 接口示例 1.0.0\r\n'
            '需要 Bingus Shared Loader v15+ 和 AutoChat API v2 revision 3 扩展。独立启用并部署此包。\r\n'
            'K → 接口示例：切换继承/独立发送、独立启用/冷却/输出方式，切换模板并手动发送。\r\n'
            '示例不订阅真实游戏事件，不会触发宿主标记或战备轮询。加载和切换菜单不会发送。\r\n'
            '继承模式遵守主设置；独立模式使用示例自己的启用状态、冷却和输出，仍通过宿主校验。\r\n'
            '本地输出失败不会回退公屏；发送不会排队。\r\n'
            '本地示例事件只调用此插件自己的处理器，不会伪造或发布游戏事件。\r\n'
            '示例消息由插件自己的字符串和处理逻辑生成；适配其他模组时可替换这些内容。\r\n'
            '游戏图标由宿主从当前已加载的catalog材质提供；资源不可用时显示说明文字。\r\n'
            '资源：' + RESOURCE + '\r\nGUID：' + GUID + '\r\n')
        for name in ('PLUGIN-API.md', 'INTERFACE-DEMO.md'):
            archive.write(ROOT / 'docs' / name, 'Docs/' + name)
    with zipfile.ZipFile(output) as archive:
        assert archive.testzip() is None
        names = set(archive.namelist())
        expected = {
            'Addon/9ba626afa44a3aa3.patch_0',
            'Addon/9ba626afa44a3aa3.patch_0.stream',
            'Addon/9ba626afa44a3aa3.patch_0.gpu_resources',
            'manifest.json', 'README.txt',
            'Docs/PLUGIN-API.md', 'Docs/INTERFACE-DEMO.md'}
        assert names == expected, 'unexpected demo archive members: ' + repr(names)
        assert archive.read('Docs/PLUGIN-API.md') == (ROOT / 'docs/PLUGIN-API.md').read_bytes()
        assert archive.read('Docs/INTERFACE-DEMO.md') == (ROOT / 'docs/INTERFACE-DEMO.md').read_bytes()
    digest = hashlib.sha256(output.read_bytes()).hexdigest()
    output.with_suffix(output.suffix + '.sha256').write_text(
        digest + '  ' + output.name + '\n', encoding='ascii')
    print(output)
    return output


if __name__ == '__main__':
    build()
