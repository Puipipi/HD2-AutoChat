"""Strict portable AutoChat profile transfer tests."""
from pathlib import Path
import sys
import unittest

from lupa.luajit21 import LuaRuntime

SOURCE = Path(__file__).resolve().parents[3] / "src" / "chat_automation.lua"
sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_chat_automation import HARNESS


class ProfileTransferTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.h = self.lua.execute(SOURCE.read_text(encoding="utf-8") + "\n" + HARNESS)

    def run_lua(self, code):
        return self.lua.execute("local h = ...; local a = h.a; " + code, self.h)

    def test_cross_controller_roundtrip_data_and_determinism(self):
        self.run_lua(r'''
            assert(a.set('welcome_message','中文\n%模板'))
            assert(a.set_rule('stratagem',4119049995,'enabled',false))
            assert(a.set_rule('stratagem',4119049995,'cooldown',0))
            assert(a.set_rule('enemy','small_enemy','mark_message',''))
            local payload=a.export_profile('host')
            assert(payload:sub(1,21)=='# AutoChat profile v1')
            assert(payload:find('rule_stratagem_4119049995.enabled=false',1,true))
            assert(payload:find('rule_stratagem_4119049995.cooldown=0',1,true))
            assert(payload:find('welcome_message=%E4%B8%AD%E6%96%87%0A%25%E6%A8%A1%E6%9D%BF',1,true))
            local b=h.new();local ok,why=b.validate_profile(payload);assert(ok,why)
            assert(b.import_profile(payload,'client'))
            assert(b.profile('client').welcome_message=='中文\n%模板')
            assert(b.rule('stratagem',4119049995,'client').enabled==false)
            assert(b.rule('stratagem',4119049995,'client').cooldown==0)
            assert(b.rule('enemy','small_enemy','client').mark_message==nil)
            assert(b.export_profile('client')==payload)
        ''')

    def test_inactive_import_does_not_touch_active_runtime(self):
        self.run_lua(r'''
            assert(a.set('ping',true));assert(a.push_ping({key='pending',category='stratagem'},10))
            local before=a.options.ping;local count=#a.state.pings
            local payload=a.export_profile('host')
            assert(a.import_profile(payload,'client'))
            assert(a.options.ping==before and #a.state.pings==count)
        ''')

    def test_active_import_updates_options_in_place_and_clears_runtime_state(self):
        self.run_lua(r'''
            assert(a.set('output','local'))
            assert(a.set('welcome_message','你好😀\n'))
            assert(a.set('ping_message','client retained','client'))
            local opts=a.options;local client_message=a.profile('client').ping_message
            local payload=a.export_profile('host')
            a.state.pending.x={due=1};a.state.pings[1]={key='old'}
            a.state.ping_seen.old=100;a.state.last_by_peer.peer=50
            a.state.last_by_rule={peer={stratagem_1=40}};a.state.baseline={session='old'}
            a.state.last_send=30
            assert(a.import_profile(payload,'host'))
            assert(a.options==opts and a.options.output=='local')
            assert(a.options.welcome_message=='你好😀\n')
            assert(next(a.state.pending)==nil and #a.state.pings==0 and next(a.state.ping_seen)==nil)
            assert(next(a.state.last_by_peer)==nil and next(a.state.last_by_rule)==nil)
            assert(a.state.baseline==nil and a.state.last_send==nil)
            assert(a.profile('client').ping_message==client_message)
        ''')

    def test_failed_save_preserves_profile_runtime_and_queue(self):
        self.run_lua(r'''
            assert(a.set('ping',true));assert(a.push_ping({key='pending',category='stratagem'},10))
            local payload=a.export_profile('host');local prior=a.export_profile('host')
            h.write_ok=false
            assert(not a.import_profile(payload,'host'))
            assert(a.export_profile('host')==prior and a.options.ping and #a.state.pings==1)
        ''')

    def test_strict_rejection_and_never_executes_lua(self):
        self.run_lua(r'''
            local p=a.export_profile('host')
            profile_executed=false
            assert(not a.validate_profile('profile_executed=true'))
            assert(profile_executed==false)
            assert(not a.validate_profile(p:sub(1,-2)))
            assert(not a.validate_profile(p..'enabled=true\n'))
            assert(not a.validate_profile(p:gsub('enabled=true','enabled=perhaps')))
            assert(not a.validate_profile(p:gsub('enabled=true\n','')))
            assert(not a.validate_profile(p..'unknown=x\n'))
            assert(not a.validate_profile(p..'ping=true\n'))
            assert(not a.validate_profile(p..string.rep('x',1048577)))
            assert(not a.validate_profile(p..'rule_enemy_small_enemy.enabled=\n'))
            assert(not a.validate_profile(p:gsub('welcome_message=[^\n]*','welcome_message=%%FF')))
            assert(not a.validate_profile(p:gsub('welcome_message=[^\n]*','welcome_message=%%C0%%AF')))
            assert(not a.validate_profile(p:gsub('welcome_message=[^\n]*','welcome_message=%%ED%%A0%%80')))
            assert(not a.validate_profile(p:gsub('welcome_message=[^\n]*','welcome_message=%%F4%%90%%80%%80')))
            assert(a.validate_profile(p:gsub('welcome_message=[^\n]*','welcome_message=%%F0%%9F%%98%%80')))
            assert(not a.import_profile(p,'other'))
        ''')


if __name__ == "__main__":
    unittest.main()
