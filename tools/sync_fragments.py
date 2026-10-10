"""Inline independently tested Lua fragments into the single-file addon."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
FRAGMENTS = [('text_input', 'UNICODE TEXT INPUT'), ('panel_input', 'ARMORY INPUT'),
             ('language', 'AUTOCHAT LANGUAGE'), ('game_language_reader', 'GAME LANGUAGE READER'),
             ('chat_automation', 'CHAT AUTOMATION'),
             ('preset_library', 'PRESET LIBRARY'),
             ('peer_identity', 'PEER IDENTITY'), ('plugin_registry', 'PLUGIN REGISTRY'),
             ('plugin_ui', 'PLUGIN UI'),
             ('marker_localization', 'MARKER LOCALIZATION'), ('special_targets', 'SPECIAL TARGETS'),
             ('ping_events', 'NATIVE PING EVENTS'),
             ('stratagem_events', 'STRATAGEM EVENTS'), ('stratagem_names_zh', 'STRATAGEM NAMES ZH'),
             ('stratagem_names_en', 'STRATAGEM NAMES EN'),
             ('stratagem_catalog', 'STRATAGEM CATALOG'),
             ('alert_panel', 'ALERT PANEL'), ('preset_panel', 'PRESET PANEL')]


def main():
    path = ROOT / 'src/auto_chat.lua'
    source = path.read_text(encoding='utf-8')
    for fragment, marker in FRAGMENTS:
        fragment_source = (ROOT / 'src' / (fragment + '.lua')).read_text(encoding='utf-8').rstrip()
        if fragment == 'plugin_ui':
            fragment_source = fragment_source.replace('local function build_plugin_ui(',
                                                        'M.build_plugin_ui = function(', 1)
            fragment_source = re.sub(r'\nreturn build_plugin_ui$', '', fragment_source)
        if fragment == 'stratagem_names_en':
            fragment_source = fragment_source.replace('local STRATAGEM_NAMES_EN = {', 'M.STRATAGEM_NAMES_EN = {', 1)
            fragment_source = re.sub(r'\nreturn STRATAGEM_NAMES_EN$', '', fragment_source)
        if fragment in ('language', 'game_language_reader', 'special_targets'):
            builder = 'build_' + fragment
            fragment_source = fragment_source.replace('local function ' + builder + '(', 'M.' + builder + ' = function(', 1)
            fragment_source = re.sub(r'\nreturn ' + builder + r'$', '', fragment_source)
        block = f'-- BEGIN {marker}\n' + fragment_source + f'\n-- END {marker}'
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
            local stratagem_catalog=build_stratagem_catalog({base=supported_game_base,read=read_at,names_zh=STRATAGEM_NAMES_ZH,names_en=M.STRATAGEM_NAMES_EN})
function M.debug_stratagem_catalog()return stratagem_catalog end
local function enrich_stratagem_event(event,now)
    if event.category~='stratagem' then return end
    stratagem_catalog.scan(now)
    local row=stratagem_catalog.lookup(event.stratagem_id)
        or stratagem_catalog.resolve_resource(event.resource)
        or stratagem_catalog.resolve_name_key(event.localization_key)
    if row then event.stratagem_id=row.id;event.stratagem_group=row.group;event.target_names=row.target_names;event.display_name=M.language.is_chinese() and row.display_name or row.display_name_en end
end
'''
            source = source.replace(anchor, block + '\n' + setup + '\n' + anchor, 1)
        elif fragment == 'text_input':
            source = source.replace('-- BEGIN ARMORY INPUT', block + '\n-- BEGIN ARMORY INPUT', 1)
        elif fragment == 'plugin_ui':
            source = source.replace('local function plugin_api(ctx)', block + '\n\nlocal function plugin_api(ctx)', 1)
        elif fragment in ('language', 'game_language_reader'):
            source = source.replace('-- BEGIN CHAT AUTOMATION', block + '\n-- BEGIN CHAT AUTOMATION', 1)
        elif fragment == 'stratagem_names_zh':
            source = source.replace('-- BEGIN STRATAGEM CATALOG', block + '\n-- BEGIN STRATAGEM CATALOG', 1)
        elif fragment == 'stratagem_names_en':
            source = source.replace('-- BEGIN STRATAGEM CATALOG', block + '\n-- BEGIN STRATAGEM CATALOG', 1)
        elif fragment == 'special_targets':
            source = source.replace('-- BEGIN NATIVE PING EVENTS',
                                    block + '\nM.special_targets = M.build_special_targets()\n-- BEGIN NATIVE PING EVENTS', 1)
            source = source.replace('M.special_targets = build_special_targets()',
                                    'M.special_targets = M.build_special_targets()')
        elif fragment == 'alert_panel':
            source = source.replace('local function draw_panel()', block + '\n\nlocal function draw_panel()', 1)
        elif fragment == 'preset_panel':
            source = source.replace('local function draw_panel()', block + '\n\nlocal function draw_panel()', 1)
        elif fragment == 'preset_library':
            source = source.replace('automation = build_chat_automation({', block + '\n\nautomation = build_chat_automation({', 1)
        else:
            raise AssertionError('Missing fragment marker: ' + marker)
    source = re.sub(
        r'local stratagem_catalog=build_stratagem_catalog\(\{base=supported_game_base,read=read_at(?:,names_zh=STRATAGEM_NAMES_ZH)?(?:,names_en=STRATAGEM_NAMES_EN)?\}\)',
        'local stratagem_catalog=build_stratagem_catalog({base=supported_game_base,read=read_at,names_zh=STRATAGEM_NAMES_ZH,names_en=M.STRATAGEM_NAMES_EN})',
        source)
    source = source.replace('M.special_targets = build_special_targets()',
                            'M.special_targets = M.build_special_targets()')
    ping_env = source.find('local ping_events = build_ping_events({')
    ping_emit = source.find('    emit = function(event, now)', ping_env)
    if ping_env >= 0 and ping_emit >= 0:
        ping_setup = source[ping_env:ping_emit]
        wiring = ('    special_targets = M.special_targets,\n'
                  "    language = function() return M.language.current() end,\n")
        ping_setup = re.sub(r'(?:' + re.escape(wiring) + r')+', wiring, ping_setup)
        if 'special_targets = M.special_targets,' not in ping_setup:
            ping_setup += wiring
        source = source[:ping_env] + ping_setup + source[ping_emit:]
    event_start = source.find('local function enrich_stratagem_event(event,now)')
    event_end = source.find('function M.debug_enrich_stratagem_event', event_start)
    if event_start >= 0 and event_end >= 0:
        event_block = '''local function enrich_stratagem_event(event,now)
    if event.category~='stratagem' then return end
    stratagem_catalog.scan(now)
    local row=stratagem_catalog.lookup(event.stratagem_id)
        or stratagem_catalog.resolve_resource(event.resource)
        or stratagem_catalog.resolve_name_key(event.localization_key)
    if row then
        event.stratagem_id=row.id;event.stratagem_rule_id=row.rule_id or row.id;event.stratagem_group=row.group
        local native=type(event.target_names)=='table' and event.target_names.native_name or nil
        local names=type(row.target_names)=='table' and {zh=row.target_names.zh,en=row.target_names.en}
            or {zh=row.display_name,en=row.display_name_en}
        if type(native)=='string' and native~='' then
            local lower=native:lower():match('^%s*(.-)%s*$')
            local generic=lower=='特殊地点' or lower=='special location'
                or lower=='敌方单位' or lower=='enemy unit' or lower=='任务交互物'
                or lower=='objective terminal' or lower=='任务终端' or lower=='mission terminal'
                or lower=='战略配备' or lower=='strategic asset' or lower=='stratagem'
                or lower=='普通物资' or lower=='supplies'
            local native_is_han=false
            local native_is_ascii=true
            local i=1
            while i<=#native do
                local a=native:byte(i)
                if a>=0x80 then native_is_ascii=false end
                if a>=0xE0 and a<=0xEF and i+2<=#native then
                    local b,c=native:byte(i+1,i+2)
                    if b>=0x80 and b<=0xBF and c>=0x80 and c<=0xBF then
                        local code=(a-0xE0)*4096+(b-0x80)*64+(c-0x80)
                        if (code>=0x3400 and code<=0x4DBF) or (code>=0x4E00 and code<=0x9FFF) then
                            native_is_han=true
                        end
                        i=i+3
                    else i=i+1 end
                elseif a>=0xC2 and a<=0xDF and i+1<=#native then i=i+2
                elseif a>=0xF0 and a<=0xF4 and i+3<=#native then i=i+4
                else i=i+1 end
            end
            if not generic and native_is_han then names.zh=native
            elseif not generic and native_is_ascii then names.en=native end
        end
        event.target_names=names
        event.display_name=M.language.is_chinese() and row.display_name or row.display_name_en
    else
        local rule=stratagem_catalog.resolve_rule_resource(event.resource)
            or stratagem_catalog.resolve_rule_name_key(event.localization_key)
        if rule then event.stratagem_rule_id=rule.id;event.stratagem_group=rule.group;event.stratagem_ambiguous=true end
    end
end
'''
        source = source[:event_start] + event_block + source[event_end:]
    path.write_text(source, encoding='utf-8')


if __name__ == '__main__':
    main()
