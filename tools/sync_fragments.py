"""Inline independently tested Lua fragments into the single-file addon."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
FRAGMENTS = [('panel_input', 'ARMORY INPUT'), ('chat_automation', 'CHAT AUTOMATION'),
             ('preset_library', 'PRESET LIBRARY'),
             ('peer_identity', 'PEER IDENTITY'), ('plugin_registry', 'PLUGIN REGISTRY'),
             ('marker_localization', 'MARKER LOCALIZATION'), ('ping_events', 'NATIVE PING EVENTS'),
             ('stratagem_events', 'STRATAGEM EVENTS'), ('stratagem_catalog', 'STRATAGEM CATALOG'),
             ('alert_panel', 'ALERT PANEL'), ('preset_panel', 'PRESET PANEL')]


def main():
    path = ROOT / 'src/auto_chat.lua'
    source = path.read_text(encoding='utf-8')
    for fragment, marker in FRAGMENTS:
        block = f'-- BEGIN {marker}\n' + (ROOT / 'src' / (fragment + '.lua')).read_text(encoding='utf-8').rstrip() + f'\n-- END {marker}'
        pattern = f'-- BEGIN {marker}\\n.*?\\n-- END {marker}'
        if re.search(pattern, source, re.S):
            source, count = re.subn(pattern, lambda _: block, source, flags=re.S)
            assert count == 1
            if fragment == 'preset_library':
                marker_at = source.find('-- BEGIN PRESET LIBRARY')
                init_at = source.find('automation = build_chat_automation({')
                if init_at < 0:
                    raise AssertionError('Missing automation initialization anchor')
                if marker_at > init_at:
                    source = re.sub(pattern, '', source, count=1, flags=re.S)
                    source = source.replace('automation = build_chat_automation({',
                                            block + '\n\nautomation = build_chat_automation({', 1)
        elif fragment == 'stratagem_catalog':
            anchor = '-- BEGIN NATIVE PING EVENTS'
            setup = '''
local stratagem_catalog=build_stratagem_catalog({base=supported_game_base,read=read_at})
function M.debug_stratagem_catalog()return stratagem_catalog end
local function enrich_stratagem_event(event,now)
    if event.category~='stratagem' then return end
    stratagem_catalog.scan(now)
    local row=stratagem_catalog.lookup(event.stratagem_id)
        or stratagem_catalog.resolve_resource(event.resource)
        or stratagem_catalog.resolve_name_key(event.localization_key)
    if row then event.stratagem_id=row.id;event.stratagem_group=row.group end
end
'''
            source = source.replace(anchor, block + '\n' + setup + '\n' + anchor, 1)
        elif fragment == 'alert_panel':
            source = source.replace('local function draw_panel()', block + '\n\nlocal function draw_panel()', 1)
        elif fragment == 'preset_panel':
            source = source.replace('local function draw_panel()', block + '\n\nlocal function draw_panel()', 1)
        elif fragment == 'preset_library':
            source = source.replace('automation = build_chat_automation({', block + '\n\nautomation = build_chat_automation({', 1)
        else:
            raise AssertionError('Missing fragment marker: ' + marker)
    path.write_text(source, encoding='utf-8')


if __name__ == '__main__':
    main()
