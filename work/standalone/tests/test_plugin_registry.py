"""Exercise plugin callback isolation and the actual independently loaded demo addon."""
from pathlib import Path
import unittest
from lupa.luajit21 import LuaRuntime

ROOT = Path(__file__).resolve().parents[3]
SOURCE = ROOT / 'src/plugin_registry.lua'
DEMO = ROOT / 'src/examples/interface_demo.lua'
HARNESS = r'''
local h={notes={},sends={},token='session-a',allowed=true,now=100,settings_value={role='host',enabled=true,
    rules={enemy_small_enemy={enabled=true,mark_message='watch'}}}}
local early={plugins={},by_id={},serial=7}
h.early=early; h.plugins=early.plugins; h.by_id=early.by_id; h.build=build_plugin_registry
h.r=build_plugin_registry({registry=early,note=function(message) h.notes[#h.notes+1]=message end,
    context=function() return h.token end,now=function() return h.now end,
    creator_key=function(creator_id) return creator_id or '0110000100000001' end,
    settings=function() return h.settings_value end,send=function(text,id,creator_id,options)
        if not h.allowed then return false,'cooldown' end
        h.sends[#h.sends+1]={text=text,id=id,creator_id=creator_id,options=options}; return true,2
    end})
return h
'''


class PluginRegistryTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(SOURCE.exists(), 'plugin registry v2 is not implemented')
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.h = self.lua.execute(SOURCE.read_text(encoding='utf-8') + '\n' + HARNESS)

    def check(self, code):
        return self.lua.execute('local h=...; local r=h.r; ' + code, self.h)

    def test_legacy_draw_registration_preserves_public_tables_and_name(self):
        self.check('''assert(r==h.early and r.plugins==h.plugins and r.by_id==h.by_id)
            assert(r.version==2 and r.api_version==2)
            local p=assert(r.register{id='legacy',title='Legacy',draw=function(u,ctx) u.hit=ctx.value end})
            local u={}; p.draw(u,{value=42}); assert(u.hit==42)
            assert(r.register{id='named',name='接口示例',draw=function() end}.title=='接口示例')
            assert(r.serial>7 and r.unregister('legacy') and not r.by_id.legacy)''')

    def test_optional_english_name_preserves_registration_identity_and_language_snapshot(self):
        self.check('''
            h.settings_value.language='en'
            local p=assert(r.register{id='localized',name='中文名',name_en='English Name',draw=function() end})
            assert(p.title=='中文名' and p.name=='中文名' and p.name_en=='English Name' and p.id=='localized')
            local held
            p._on_click=function(_,api) held=api end
            r.click('localized','capture')
            assert(held.settings().language=='en')
            assert(r.register{id='bad-locale',name='中文',name_en='bad\\nname',draw=function() end}==nil)
        ''')

    def test_sender_forwards_optional_trigger_peer_and_rejects_malformed_ids(self):
        self.check('''local api
            r.register{id='aware',name='Aware',draw=function() end,
                on_click=function(key,current) api=current end}
            r.click('aware','capture')
            assert(api.send('欢迎 {玩家名}','01100001000000af'))
            assert(h.sends[1].creator_id=='01100001000000AF')
            assert(api.send('bad','not-an-id')==false and #h.sends==1)
            assert(api.send('local') and h.sends[2].creator_id==nil)
        ''')

    def test_duplicate_invalid_and_over_limit_registration_changes_nothing(self):
        self.check('''assert(r.register(nil)==nil)
            for _,s in ipairs({{id='',draw=function() end},{id='a',name='',draw=function() end},
                {id='bad id',draw=function() end},{id='a',draw=42},
                {id='a',draw=function() end,on_click=true},{id=string.rep('a',65),draw=function() end}}) do
                assert(r.register(s)==nil)
            end
            assert(#r.plugins==0)
            for i=1,16 do assert(r.register{id='p'..i,draw=function() end}) end
            local serial=r.serial
            assert(r.register{id='p1',draw=function() end}==nil)
            assert(r.register{id='overflow',draw=function() end}==nil)
            assert(#r.plugins==16 and r.serial==serial)''')

    def test_click_callback_sends_only_through_registered_policy_api(self):
        self.check('''local held
            assert(r.register{id='a',draw=function() end,on_click=function(key,api)
                assert(api.version==2 and api.id=='a' and api.context()==h.token)
                held=api; return api.send(key)
            end})
            local ok,count=r.click('a','hello'); assert(ok and count==2)
            assert(h.sends[1].text=='hello' and h.sends[1].id=='a')
            h.allowed=false; local allowed,why=r.send('a','later'); assert(not allowed and why=='cooldown')
            assert(r.send('missing','bad')==false and #h.sends==1)
            assert(r.send('a',string.rep('x',513))==false)
            assert(r.send('a','bad'..string.char(0))==false)
            r.unregister('a'); assert(held.send('stale')==false)
            assert(r.click('missing','hello')==false)''')

    def test_callback_faults_do_not_escape_or_disable_other_plugins(self):
        self.check('''local good=0
            local bad=assert(r.register{id='bad',draw=function() error('draw fail') end,
                on_click=function() error('click fail') end,on_event=function() error('event fail') end,
                revision=function() error('revision fail') end})
            assert(r.register{id='good',draw=function() end,on_event=function() good=good+1 end})
            assert(pcall(bad.draw,{},{})); assert(r.click('bad','x')==false)
            assert(type(r.signature())=='string'); r.publish{type='ping'}
            assert(good==1 and bad.faults>=4 and #h.notes>0)''')

    def test_revision_changes_signature_without_drawing(self):
        self.check('''local rev=0
            assert(r.register{id='p',draw=function() error('must not draw') end,revision=function() return rev end})
            local before=r.signature(); rev=1; assert(r.signature()~=before)
            local after=r.signature(); assert(r.signature()==after)
            r.unregister('p'); assert(r.signature()~=after)''')

    def test_publish_copies_nested_event_per_plugin_and_is_stable_during_unregister(self):
        self.check('''local observed
            assert(r.register{id='a',draw=function() end,on_event=function(e)
                e.data.value='mutated'; r.unregister('a')
            end})
            assert(r.register{id='b',draw=function() end,on_event=function(e,api)
                observed=e.data.value; assert(api.id=='b')
            end})
            local event={type='ping',data={value='original'}}
            assert(r.publish(event)==2)
            assert(event.data.value=='original' and observed=='original')
            assert(r.publish('bad')==0)''')

    def test_existing_early_registered_specs_are_adopted(self):
        self.check('''local spec={id='early',title='Early',draw=function(u) u.hit=true end}
            local registry={plugins={spec},by_id={early=spec}}
            local r=h.build{registry=registry}
            assert(r.by_id.early and #r.plugins==1)
            local u={}; r.plugins[1].draw(u,{}); assert(u.hit)''')

    def test_retained_callback_api_cannot_send_into_another_session_or_replacement_plugin(self):
        self.check('''local held
            local function spec() return {id='a',draw=function() end,
                on_click=function(_,api) held=api end} end
            assert(r.register(spec())); r.click('a','hold')
            h.token='session-b'; local ok,why=held.send('old session')
            assert(not ok and why=='session changed' and #h.sends==0)
            r.click('a','hold'); local old=held
            r.unregister('a'); assert(r.register(spec()))
            assert(old.send('old registration')==false and #h.sends==0)''')

    def test_cyclic_event_is_copied_without_exposing_original_or_native_values(self):
        self.check('''local received
            r.register{id='a',draw=function() end,on_event=function(e) received=e end}
            local event={type='ping',number=42,flag=false,callback=function() end}
            event.self=event; r.publish(event)
            assert(received~=event and received.type=='ping' and received.number==42)
            assert(received.flag==false and received.self==nil and received.callback==nil)''')

    def test_sender_exception_is_contained_and_attributed(self):
        self.check('''local r=h.build{send=function() error('native boundary refused') end,
                note=function(value) h.notes[#h.notes+1]=value end}
            assert(r.register{id='source_mod',draw=function() end})
            local ok,why=r.send('source_mod','hello'); assert(not ok and why=='sender failed')
            assert(h.notes[#h.notes]:find('source_mod',1,true))''')

    def test_v2_revision3_settings_snapshot_and_old_handshake(self):
        self.check('''assert(r.version==2 and r.api_version==2 and r.api_revision==3)
            assert(r.capabilities.independent_send and r.capabilities.settings)
            local callback
            r.register{id='legacy',draw=function() end,on_click=function(_,api)
                assert(api.version==2 and api.api_version==2 and api.api_revision==3)
                assert(api.capabilities.settings and api.capabilities.independent_send)
                callback=api
            end}
            assert(r.click('legacy','capture'))
            local snapshot=assert(callback.settings())
            assert(snapshot.role=='host' and snapshot.rules.enemy_small_enemy.mark_message=='watch')
            snapshot.rules.enemy_small_enemy.mark_message='changed'
            assert(h.settings_value.rules.enemy_small_enemy.mark_message=='watch')
            h.token='session-b'; local stale,why=callback.settings()
            assert(stale==nil and why=='session changed')
            assert(callback.send('legacy old form')==false)
        ''')

    def test_independent_send_isolated_bounded_and_does_not_commit_failed_attempts(self):
        self.check('''local a,b,held
            assert(r.register{id='a',draw=function() end,on_click=function(_,api) a=api end})
            assert(r.register{id='b',draw=function() end,on_click=function(_,api) b=api end})
            r.click('a','capture');r.click('b','capture')
            local opt={policy='independent',cooldown=5,cooldown_key='alert',output='local'}
            assert(a.send('one','0110000100000001',opt))
            assert(h.sends[1].options and h.sends[1].options.output=='local')
            assert(not a.send('blocked','0110000100000001',opt))
            assert(a.send('other peer','0110000100000002',opt))
            assert(a.send('other key','0110000100000001',{policy='independent',cooldown=5,cooldown_key='other'}))
            assert(b.send('other plugin','0110000100000001',opt))
            assert(a.send('zero a','0110000100000003',{policy='independent',cooldown=0}))
            assert(a.send('zero b','0110000100000003',{policy='independent',cooldown=0}))
            assert(a.send('self alias',nil,{policy='independent',cooldown=5,cooldown_key='self-alias'}))
            assert(not a.send('same self bucket','0110000100000001',
                {policy='independent',cooldown=5,cooldown_key='self-alias'}))
            h.allowed=false
            assert(not a.send('failed','0110000100000004',opt))
            h.allowed=true
            assert(a.send('retry after failure','0110000100000004',opt))
            h.now=h.now+5
            assert(a.send('expired','0110000100000001',opt))
            assert(r.register{id='capacity',draw=function() end,on_click=function(_,api) held=api end})
            r.click('capacity','capture')
            for i=1,128 do
                assert(held.send('key'..i,'0110000100000010',{policy='independent',cooldown=60,
                    cooldown_key='capacity-'..i}))
            end
            assert(not held.send('over cap','0110000100000010',{policy='independent',cooldown=60,
                cooldown_key='capacity-over'}))
            assert(not held.send('existing remains','0110000100000010',{policy='independent',cooldown=60,
                cooldown_key='capacity-1'}))
            h.now=h.now+60
            assert(held.send('expired frees slot','0110000100000010',{policy='independent',cooldown=60,
                cooldown_key='capacity-over'}))
            assert(held.send('unlimited zero','0110000100000011',{policy='independent',cooldown=0,
                cooldown_key='zero-'..string.rep('z',59)}))
        ''')

    def test_policy_validation_and_unregister_session_cleanup(self):
        self.check('''local held
            assert(r.register{id='safe',draw=function() end,on_click=function(_,api) held=api end})
            r.click('safe','capture')
            assert(not held.send('invalid override',nil,{output='local'}))
            assert(not held.send('invalid policy',nil,{policy='magic'}))
            assert(not held.send('unknown option',nil,{policy='independent',native=true}))
            assert(not held.send('bad cooldown',nil,{policy='independent',cooldown=0/0}))
            assert(not held.send('bad cooldown',nil,{policy='independent',cooldown=-1}))
            assert(not held.send('bad key',nil,{policy='independent',cooldown_key=string.rep('x',65)}))
            assert(not held.send('bad output',nil,{policy='independent',output='fallback'}))
            local opt={policy='independent',cooldown=30,cooldown_key='one'}
            assert(held.send('first','0110000100000001',opt))
            assert(r.unregister('safe'))
            assert(not held.send('stale'))
            local second
            r.register{id='safe',draw=function() end,on_click=function(_,api) second=api end}
            r.click('safe','capture'); assert(second.send('new plugin same id','0110000100000001',opt))
            h.token='session-b'
            assert(not second.send('stale session','0110000100000002',opt))
            r.click('safe','capture')
            assert(r.send('safe','fresh session','0110000100000001',opt))
        ''')

    def test_oversized_settings_snapshot_is_rejected_instead_of_truncated(self):
        self.check('''r.register{id='large',draw=function() end}
            h.settings_value={role='host',enabled=true,large={}}
            for i=1,16385 do h.settings_value.large[i]='value' end
            local snapshot,why=r.settings('large')
            assert(snapshot==nil and why=='settings snapshot too large')''')

    def test_demo_late_load_registers_immediately_and_remains_passive(self):
        self.lua.globals().HD2AutoChatPlugins = self.h.r
        self.lua.execute(DEMO.read_text(encoding='utf-8'))
        self.check('''assert(r.by_id.auto_chat_demo and #r.plugins==1 and #h.sends==0)
            r.publish{type='ping',category='mission'}; assert(#h.sends==0)
            assert(r.signature():find('auto_chat_demo',1,true))''')

    def test_demo_addon_loads_early_without_subscribing_to_game_events(self):
        self.assertTrue(DEMO.exists(), 'example addon is missing')
        self.lua.globals().HD2AutoChatPlugins = None
        self.lua.execute(DEMO.read_text(encoding='utf-8'))
        self.check('''local pending=HD2AutoChatPending['auto_chat_demo']; assert(pending.name=='接口示例')
            assert(#h.sends==0); assert(r.register(pending)); HD2AutoChatPlugins=r
            local buttons,texts={},{}
            local u={button=function(key,label) buttons[#buttons+1]={key=key,label=label} end,
                text=function(value) texts[#texts+1]=value end}
            r.by_id.auto_chat_demo.draw(u,{})
            assert(#buttons==7 and #texts>=1)
            assert(buttons[1].key=='mode' and buttons[1].label=='发送模式：继承主设置')
            assert(buttons[2].key=='enabled' and buttons[2].label=='独立发送：开')
            assert(buttons[3].key=='cooldown' and buttons[3].label=='独立冷却：0秒')
            assert(buttons[4].key=='output' and buttons[4].label=='独立输出：继承主设置')
            assert(buttons[5].key=='template' and buttons[5].label=='切换自定义消息模板')
            assert(buttons[6].key=='send' and buttons[6].label=='手动发送预览消息')
            assert(buttons[7].key=='sample' and buttons[7].label=='本地示例事件并手动发送')
            assert(pending.on_event==nil and r.by_id.auto_chat_demo._on_event==nil)
            assert(r.publish{type='ping',category='large_enemy'}==0)
            assert(#h.sends==0, 'a menu-only example must not subscribe or send on publication')
            assert(r.click('auto_chat_demo','template') and #h.sends==0)
            r.click('auto_chat_demo','send')
            assert(#h.sends==1 and h.sends[1].id=='auto_chat_demo')
            assert(h.sends[1].text=='AutoChat 接口示例：自定义消息 Beta')
            r.click('auto_chat_demo','sample')
            assert(#h.sends==2 and h.sends[2].text=='AutoChat 接口示例：本地示例事件 #1（地图标记）')''')
        self.lua.execute(DEMO.read_text(encoding='utf-8'))
        self.check("assert(#r.plugins==1, 'duplicate demo loads must not create duplicate tabs')")


if __name__ == '__main__':
    unittest.main()
