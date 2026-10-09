"""Behavior tests for automatic chat policy; runs without the game or native FFI."""
from pathlib import Path
import unittest

from lupa.luajit21 import LuaRuntime


SOURCE = Path(__file__).resolve().parents[3] / "src" / "chat_automation.lua"
HARNESS = r'''
local h = { session = 'session-a', mine = '76561198000000001',
    host = '76561198000000001', peers = {'76561198000000001'},
    context = 'context-a', sent = {}, writes = {}, diagnostics = {}, write_ok = true, send_ok = true, identities = {} }
local sr = {
    Network = {game_session = function() return h.session end,
               peer_id = function() return h.mine end},
    GameSession = {in_session = function() return h.in_session ~= false end,
        peers = function() return h.peers end,
        game_session_host = function() return h.host end} }
h.sr = sr
h.factory = build_chat_automation
function h.new(content)
    return build_chat_automation({engine = function() return h.sr end,
        context = function() return h.context end,
        identity = function(peer) return h.identities[peer] end,
        colorize = function(prefix, argb) return '<c=' .. argb .. '>' .. prefix .. '<c=FFFFFFFF>' end,
        read_file = function() return content end,
        diagnostic = function(category,action,stable_id,result,output)
            h.diagnostics[#h.diagnostics+1]={category,action,stable_id,result,output}
        end,
        write_file = function(value)
            h.writes[#h.writes + 1] = value
            if h.throw_write then error('disk unavailable') end
            return h.write_ok
        end,
        send = function(text)
            h.sent[#h.sent + 1] = text
            return h.send_ok, 'text chat is off'
        end,
        send_local = function(text)
            h.local_sent = h.local_sent or {};h.local_sent[#h.local_sent+1]=text
            return true,'local'
        end})
end
h.a = h.new()
return h
'''


class AutomationTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(SOURCE.exists(), "automatic chat policy fragment is not implemented")
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.h = self.lua.execute(SOURCE.read_text(encoding="utf-8") + "\n" + HARNESS)

    def run_lua(self, code):
        return self.lua.execute("local h = ...; local a = h.a; " + code, self.h)

    def test_role_profiles_migrate_old_settings_and_save_independently(self):
        self.run_lua('''
            local b=h.new('welcome=true\\nping=true\\nping_message=旧消息\\n')
            assert(b.profile('host').welcome and b.profile('host').ping_message=='旧消息')
            assert(not b.profile('client').welcome and b.profile('client').output=='local')
            assert(b.set('ping_message','客机消息','client'))
            assert(b.profile('host').ping_message=='旧消息')
            local c=h.new(h.writes[#h.writes])
            assert(c.profile('client').ping_message=='客机消息')
            assert(c.profile('host').welcome)
        ''')

    def test_settings_returns_a_detached_snapshot_of_the_confirmed_active_profile(self):
        self.run_lua('''
            a.set('cooldown',17,'host')
            a.set_rule('enemy','large_enemy','enabled',false,'host')
            a.set_rule('enemy','large_enemy','enabled',true,'client')
            local host=a.settings()
            assert(host.role=='host' and host.cooldown==17)
            assert(host.rules.enemy_large_enemy.enabled==false)
            host.cooldown=999;host.rules.enemy_large_enemy.enabled=true
            assert(a.profile('host').cooldown==17)
            assert(a.rule('enemy','large_enemy','host').enabled==false)
            h.host='76561198000000002';h.peers={h.mine,h.host}
            local client=a.settings()
            assert(client.role=='client' and client.output=='local')
            client.rules.enemy_large_enemy.enabled=true
            assert(a.rule('enemy','large_enemy','client').enabled==true)
            h.host=nil
            local unknown,why=a.settings()
            assert(unknown==nil and why=='role unavailable')
        ''')

    def test_send_output_override_uses_existing_local_and_public_senders(self):
        self.run_lua('''
            assert(a.send('private',nil,'local'))
            assert(#h.sent==0 and #h.local_sent==1 and h.local_sent[1]=='private')
            assert(a.send('public',nil,'squad'))
            assert(h.sent[#h.sent]=='public' and #h.local_sent==1)
        ''')

    def test_legacy_host_scope_is_ignored_for_a_client_profile(self):
        self.run_lua('''
            h.host='76561198000000002';h.peers={h.mine,h.host}
            local b=h.new('# AutoChat automation settings v4\\nhost.scope=host\\nclient.scope=host\\n')
            assert(b.sync()=='client')
            assert(b.check(1000,1,h.mine))
            assert(b.profile('client').scope==nil)
            assert(b.set('scope','host','client')==false)
        ''')

    def test_stratagem_event_diagnostic_covers_rule_gate_queue_and_send(self):
        self.run_lua('''
            a.set('ping',true)
            a.set('ping_sender_prefix',false)
            a.set_rule('stratagem',4119049995,'enabled',false)
            local disabled={key='event-disabled',category='stratagem',action='summon',
                stratagem_id=4119049995,creator_id=h.mine}
            assert(not a.push_ping(disabled,100))
            assert(#a.state.pings==0)
            local gate=h.diagnostics[#h.diagnostics]
            assert(gate[1]=='stratagem' and gate[2]=='summon' and gate[3]=='stratagem_4119049995')
            assert(gate[4]=='rule-disabled' and gate[5]=='squad')

            a.set_rule('stratagem',4119049995,'enabled',true)
            a.set_rule('stratagem',4119049995,'cooldown',0)
            local enabled={key='event-enabled',category='stratagem',action='summon',
                stratagem_id=4119049995,creator_id=h.mine,target='fixture target'}
            assert(a.push_ping(enabled,101))
            assert(#a.state.pings==1)
            assert(a.poll(101))
            local queued,sent
            for _,item in ipairs(h.diagnostics) do
                if item[3]=='stratagem_4119049995' and item[1]=='stratagem' then
                    if item[4]=='queued' then queued=item end
                    if item[4]=='sent' then sent=item end
                end
            end
            assert(queued and queued[5]=='squad' and sent and sent[5]=='squad')
            assert(h.sent[#h.sent]=='队友召唤了fixture target')
        ''')

    def test_client_output_never_falls_back_to_public_chat(self):
        self.run_lua('''
            h.host='76561198000000002';h.peers={h.mine,h.host}
            local n=0;h.local_ok=false
            local b=h.factory({engine=function()return h.sr end,
                context=function()return h.context end,write_file=function()return true end,
                send=function()n=n+1;return true end,
                send_local=function()return h.local_ok,'local unavailable' end})
            assert(b.sync()=='client'); assert(b.options.output=='local')
            assert(not b.send('private')); assert(n==0)
            h.local_ok=true;assert(b.send('private'));assert(n==0)
            h.host=h.mine;assert(b.send('public'));assert(n==1)
        ''')

    def test_role_change_cancels_old_pending_messages_and_cooldown(self):
        self.run_lua('''
            assert(a.set('ping',true));assert(a.set('welcome',true))
            assert(a.push_ping({key='old',category='stratagem',target='旧标记'},1000))
            a.record(1000)
            h.host='76561198000000002';h.peers={h.mine,h.host}
            assert(a.sync()=='client');assert(#a.state.pings==0)
            assert(next(a.state.pending)==nil and next(a.state.last_by_peer)==nil)
            assert(not a.options.welcome and a.options.output=='local')
        ''')

    def test_inactive_profile_edits_do_not_change_active_output_or_clear_queue(self):
        self.run_lua('''
            a.sync();assert(a.set('ping',true))
            assert(a.push_ping({key='kept',category='stratagem'},1000))
            assert(a.set('enabled',false,'client'));assert(a.options.enabled)
            assert(#a.state.pings==1)
            h.write_ok=false
            assert(not a.set('output','squad','client'))
            assert(a.profile('client').output=='local')
        ''')

    def test_unknown_identity_cannot_broadcast_using_previous_host_preset(self):
        self.run_lua('''
            a.sync();h.host=nil
            assert(not a.send('must not leak'));assert(#h.sent==0)
            assert(not a.set('output','invalid','host'))
            assert(not a.set('welcome',true,'invalid'))
        ''')

    def test_client_ping_and_explicit_client_welcome_use_only_local_output(self):
        self.run_lua('''
            h.host='76561198000000002';h.peers={h.mine,h.host}
            assert(a.set('ping',true,'client'));assert(a.set('cooldown',0,'client'))
            assert(a.push_ping({key='mark',category='medium_enemy',target='武斗虫',creator_id=h.host},1000))
            assert(a.poll(1000));assert(#h.sent==0 and #h.local_sent==1)
            assert(h.local_sent[1]:find('武斗虫',1,true))
            assert(a.set('welcome',true,'client'));a.poll(1001)
            h.peers[3]='76561198000000003';a.poll(1002);assert(a.poll(1004))
            assert(#h.sent==0 and #h.local_sent==2)
            assert(not a.send('old host message','host'));assert(#h.sent==0)
        ''')

    def test_task_execution_has_a_custom_persistent_template_and_obeys_call_switch(self):
        self.run_lua("""
            h.identities[h.mine]={peer_id=h.mine,name='Alice',short='A1',color_index=0}
            assert(a.set('ping',true));assert(a.set('ping_sender_prefix',false))
            assert(a.push_ping({key='upload',category='stratagem',action='use',target='上传数据',creator_id=h.mine},1000))
            assert(a.poll(1000));assert(h.sent[1]=='Alice正在开始上传数据',h.sent[1])
            assert(a.set('task_stratagem_message','{缩写}：正在{动作}{目标}'))
            local b=h.new(h.writes[#h.writes]);assert(b.options.task_stratagem_message=='{缩写}：正在{动作}{目标}')
            assert(a.push_ping({key='upload2',category='stratagem',action='use',target='上传数据',creator_id=h.mine},1005))
            assert(a.set('ping_summon',false));a.poll(1005);assert(#h.sent==1)
            assert(a.push_ping({key='upload3',category='stratagem',action='use',target='上传数据'},1010)==false)
        """)

    def test_shared_task_call_never_impersonates_the_local_player(self):
        self.run_lua("""
            h.identities[h.mine]={peer_id=h.mine,name='Alice',short='A1',color_index=0}
            assert(a.set('ping',true))
            assert(a.push_ping({key='teamflag',category='stratagem',action='summon',target='超级地球旗帜',anonymous=true},1000))
            assert(a.poll(1000));assert(h.sent[1]=='小队召唤了超级地球旗帜',h.sent[1])
        """)

    def test_legacy_stock_template_shows_target_but_custom_templates_are_preserved(self):
        self.run_lua('''
            local b=h.new('ping=true\\nping_sender_prefix=false\\nping_message=队友标记了{类别}，请注意！\\n')
            assert(b.push_ping({key='supply',category='stratagem',target='M-103 补给车'},1000))
            assert(b.poll(1000)); assert(h.sent[1]:find('M-103 补给车',1,true),h.sent[1])
            local c=h.new('ping_message=我的消息：{类别}\\n')
            assert(c.options.ping_message=='我的消息：{类别}')
            assert(b.set('ping_message','队友标记了{类别}，请注意！'))
            local d=h.new(h.writes[#h.writes])
            assert(d.options.ping_message=='队友标记了{类别}，请注意！','explicitly saved v2 template must round trip')
        ''')

    def test_stratagem_display_label_precedes_debug_target_in_message(self):
        self.run_lua(r'''
            assert(a.set('ping',true));assert(a.set('ping_sender_prefix',false))
            assert(a.set('ping_message','{目标}'))
            assert(a.push_ping({key='zh-name',category='stratagem',target='ORBITAL.NAPALM',
                display_name='轨道凝固汽油弹幕'},1000))
            assert(a.state.pings[1].text=='轨道凝固汽油弹幕')
        ''')

    def test_summons_use_a_named_separate_template_and_do_not_relabel_manual_pings(self):
        self.run_lua('''
            h.identities[h.mine]={peer_id=h.mine,name='Alice',short='A1',color_index=0}
            assert(a.set('ping',true));assert(a.set('ping_sender_prefix',false))
            assert(a.push_ping({key='call',category='stratagem',action='summon',target='重新补给',creator_id=h.mine},1000))
            assert(a.poll(1000));assert(h.sent[1]=='Alice召唤了重新补给',h.sent[1])
            assert(a.push_ping({key='mark',category='stratagem',action='mark',target='重新补给',creator_id=h.mine},1005))
            assert(a.poll(1005));assert(h.sent[2]=='标记了重新补给（战备提示）',h.sent[2])
            assert(a.set('summon_message','{缩写}{动作}了{目标}'))
            local b=h.new(h.writes[#h.writes]);assert(b.options.summon_message=='{缩写}{动作}了{目标}')
            assert(a.push_ping({key='call2',category='stratagem',action='summon',target='激光大炮',creator_id=h.mine},1010))
            assert(a.poll(1010));assert(h.sent[3]=='A1召唤了激光大炮')
        ''')

    def test_summon_switch_and_equipment_mark_switch_are_independent(self):
        self.run_lua('''
            assert(a.set('ping',true));assert(a.set('ping_stratagem',false))
            assert(a.push_ping({key='call',category='stratagem',action='summon',target='重新补给'},1000))
            assert(a.push_ping({key='mark',category='stratagem',action='mark',target='重新补给'},1000)==false)
            assert(a.poll(1000));assert(h.sent[1]:find('召唤了重新补给',1,true))
            assert(a.set('ping_summon',false));assert(a.set('ping_stratagem',true))
            assert(a.push_ping({key='call2',category='stratagem',action='summon',target='重新补给'},1001)==false)
            assert(a.push_ping({key='mark2',category='stratagem',action='mark',target='重新补给'},1001))
        ''')

    def test_switching_off_summons_cancels_queued_call_in_only(self):
        self.run_lua('''
            assert(a.set('ping',true));assert(a.set('ping_sender_prefix',false))
            assert(a.push_ping({key='call',category='stratagem',action='summon',target='重新补给'},1000))
            assert(a.push_ping({key='mark',category='stratagem',target='激光大炮'},1000))
            assert(a.set('ping_summon',false));assert(a.poll(1000))
            assert(#h.sent==1 and h.sent[1]=='标记了激光大炮（战备提示）')
            assert(not a.poll(1010));assert(#h.sent==1)
        ''')

    def test_defaults_and_unknown_host_policy(self):
        self.run_lua("""
            assert(a.options.enabled and a.options.allow_solo and not a.options.welcome)
            assert(a.options.scope == nil and a.options.cooldown == 5)
            assert(a.options.welcome_delay == 2)
            h.sr = nil
            assert(a.check(0, 1))
            assert(a.set('scope', 'host') == false)
            local ok, why = a.check(0, 1)
            assert(ok == true)
            assert(a.push_ping({key='unknown-role',category='stratagem'},0)==false)
        """)

    def test_transient_ping_rejections_are_retryable(self):
        self.run_lua("""
            h.sr = nil
            local ok, disposition = a.push_ping({key='role-retry',category='stratagem'},100)
            assert(ok == false and disposition == 'retry', 'unknown role must not consume a live marker')
        """)

    def test_missing_creator_and_full_ping_queues_are_retryable_without_eviction(self):
        self.run_lua("""
            a.set('ping',true)
            local missing, missing_disposition = a.push_ping({key='roster-retry',category='stratagem',
                creator_id='76561198000000002'},101)
            assert(missing == false and missing_disposition == 'retry', 'temporarily absent creator must be retryable')
            a.set_rule('stratagem',4119049994,'cooldown',5)
            a.set_rule('stratagem',4119049995,'cooldown',0)
            for i=1,16 do assert(a.push_ping({key='normal-'..i,category='stratagem',
                stratagem_id=4119049994},200+i)) end
            local full_normal, normal_disposition = a.push_ping({key='normal-retry',category='stratagem',
                stratagem_id=4119049994},220)
            assert(full_normal == false and normal_disposition == 'retry', 'full normal quota must be retryable')
        """)

    def test_urgent_reserve_does_not_evict_accepted_normal_pings(self):
        self.run_lua("""
            a.set('ping',true)
            a.set_rule('stratagem',4119049994,'cooldown',5)
            a.set_rule('stratagem',4119049995,'cooldown',0)
            for i=1,16 do assert(a.push_ping({key='normal-'..i,category='stratagem',
                stratagem_id=4119049994},200+i)) end
            assert(a.push_ping({key='urgent-1',category='stratagem',stratagem_id=4119049995,
                target='urgent'},221), 'urgent reserve must accept zero-cooldown event')
            for i=2,16 do assert(a.push_ping({key='urgent-'..i,category='stratagem',
                stratagem_id=4119049995},220+i)) end
            assert(#a.state.pings == 32, 'queue should preserve 16 normal and 16 urgent accepted events')
            for i=1,16 do
                local found=false
                for _,pending in ipairs(a.state.pings) do if pending.key=='normal-'..i then found=true end end
                assert(found, 'accepted normal message '..i..' was evicted')
            end
        """)

    def test_full_ping_queue_returns_retry_without_dropping_accepted_events(self):
        self.run_lua("""
            a.set('ping',true)
            a.set_rule('stratagem',4119049994,'cooldown',5)
            a.set_rule('stratagem',4119049995,'cooldown',0)
            for i=1,16 do assert(a.push_ping({key='normal-'..i,category='stratagem',
                stratagem_id=4119049994},200+i)) end
            for i=1,16 do assert(a.push_ping({key='urgent-'..i,category='stratagem',
                stratagem_id=4119049995},220+i)) end
            local full, full_disposition = a.push_ping({key='full-retry',category='stratagem',
                stratagem_id=4119049995},300)
            assert(full == false and full_disposition == 'retry', 'full queue must leave live marker retryable')
            assert(#a.state.pings == 32, 'queue must be bounded at 32 and preserve all accepted messages')
        """)

    def test_zero_cooldown_ping_is_sent_before_older_normal_queue(self):
        self.run_lua("""
            a.set('ping',true);a.set('ping_sender_prefix',false)
            a.set('cooldown',0)
            a.set_rule('stratagem',4119049994,'cooldown',5)
            a.set_rule('stratagem',4119049995,'cooldown',0)
            assert(a.push_ping({key='normal-first',category='stratagem',stratagem_id=4119049994,
                target='normal'},100))
            assert(a.push_ping({key='urgent-next',category='stratagem',stratagem_id=4119049995,
                target='urgent'},101))
            assert(a.poll(102))
            assert(#h.sent==1 and h.sent[1]:find('urgent',1,true), 'zero-cooldown event should keep priority')
            assert(#a.state.pings==1 and a.state.pings[1].key=='normal-first', 'normal accepted item must remain queued')
        """)

    def test_permanent_ping_rejections_are_not_retryable(self):
        self.run_lua("""
            a.set('ping',false)
            local disabled, disposition = a.push_ping({key='disabled',category='stratagem'},100)
            assert(disabled == false and disposition == nil, 'user-disabled events must not be retried')
            a.set('ping',true)
            local invalid, invalid_disposition = a.push_ping({category='stratagem'},101)
            assert(invalid == false and invalid_disposition == nil, 'invalid events are permanent rejects')
            local event={key='duplicate',category='stratagem'}
            assert(a.push_ping(event,102))
            local duplicate, duplicate_disposition = a.push_ping(event,103)
            assert(duplicate == false and duplicate_disposition == nil, 'duplicates are permanent rejects')
        """)

    def test_buildings_and_stratagems_replace_pickups_and_migrate_existing_preferences(self):
        self.run_lua('''
            assert(a.options.ping_building and a.options.ping_stratagem and a.options.ping_map)
            assert(a.options.ping_small_items == nil)
            local b=h.new('ping_mission=false\\nping_small_items=false\\n')
            assert(b.options.ping_building == false and b.options.ping_stratagem == false)
            local c=h.new('ping_mission=false\\nping_building=true\\n')
            assert(c.options.ping_building == true)
            assert(a.set('ping',true))
            assert(a.push_ping({key='ammo',category='small_items'},1000)==false)
            for _,category in ipairs({'building','stratagem','map'}) do
                assert(a.push_ping({key=category,category=category},1000))
            end
        ''')

    def test_own_ping_sends_without_profile_and_shares_local_timer_cooldown(self):
        self.run_lua('''
            h.mine='76561197960265745'; h.host=h.mine; h.peers={h.mine}
            assert(a.set('ping',true))
            assert(a.set('ping_sender_prefix',false)); assert(a.set('ping_message','{目标}'))
            assert(a.push_ping({key='own1',category='stratagem',creator_id='0110000100000011',
                target='LAS-98 激光大炮'},1000))
            assert(a.poll(1000)); assert(h.sent[1]=='LAS-98 激光大炮')
            assert(a.check(1001,0)==false, 'own ping must consume the local timer bucket')
            assert(a.push_ping({key='own2',category='map',creator_id='0110000100000011',
                target='地图标记'},1001))
            assert(a.poll(1001)==false); assert(a.poll(1005)); assert(h.sent[2]=='地图标记')
            assert(a.set('allow_solo',false))
            assert(a.push_ping({key='own3',category='map',creator_id='0110000100000011'},1010))
            assert(a.poll(1010)==false and #h.sent==2)
        ''')

    def test_objective_templates_use_runtime_category_and_localized_name(self):
        self.run_lua('''
            assert(a.set('ping',true)); assert(a.set('ping_sender_prefix',false))
            assert(a.set('ping_message','{任务类型}：{任务名} / {目标}'))
            for n,kind in ipairs({'primary','prerequisite','optional','tactical','unknown'}) do
                assert(a.push_ping({key='obj'..n,category='map',target='摧毁非法广播',
                    objective_name='摧毁非法广播',objective_kind=kind},1000+n*5))
                assert(a.poll(1000+n*5))
            end
            assert(h.sent[1]=='主线任务：摧毁非法广播 / 摧毁非法广播')
            assert(h.sent[2]=='主线前置任务：摧毁非法广播 / 摧毁非法广播')
            assert(h.sent[3]=='支线任务：摧毁非法广播 / 摧毁非法广播')
            assert(h.sent[4]=='战术任务：摧毁非法广播 / 摧毁非法广播')
            assert(h.sent[5]=='任务：摧毁非法广播 / 摧毁非法广播')
        ''')

    def test_trigger_identity_and_position_templates_are_plain_and_prefix_is_optional(self):
        self.run_lua('''
            assert(a.set('ping',true)); assert(a.set('ping_sender_color',false))
            assert(a.set('ping_message','{触发者}：{目标} {位置}'))
            h.identities.friend={peer_id='friend',name='Alice',short='AL',color='FF0000'}
            assert(a.push_ping({key='map1',category='map',creator_id='friend',target='地图标记',
                position={x=123,y=456,z=7}},1000))
            assert(a.poll(1000)); assert(h.sent[1]=='[AL] Alice：地图标记 (123, 456, 7)')
            assert(a.set('ping_sender_prefix',false))
            assert(a.push_ping({key='map2',category='map',creator_id='friend',target='地图标记'},1005))
            assert(a.poll(1005)); assert(h.sent[2]=='Alice：地图标记 未知位置')
        ''')

    def test_native_localized_target_truncation_preserves_utf8_boundaries(self):
        sent = self.run_lua('''
            assert(a.set('ping',true)); assert(a.set('ping_message','{目标}'))
            assert(a.push_ping({key='long-target',category='building',target=string.rep('塔',80)},1000))
            assert(a.poll(1000)); return h.sent[1]
        ''')
        self.assertEqual(sent, '塔' * 66)

    def test_queued_ping_is_discarded_if_trigger_identity_leaves_before_send(self):
        self.run_lua('''
            assert(a.set('ping',true)); a.record(1000)
            h.identities.friend={peer_id='friend',name='Alice',short='AL'}
            assert(a.push_ping({key='join',category='building',creator_id='friend'},1001))
            h.identities.friend=nil
            assert(a.poll(1005)==false and #h.sent==0)
        ''')

    def test_queued_ping_from_departed_peer_is_dropped_without_profile_metadata(self):
        self.run_lua('''
            assert(a.set('ping',true)); a.record(1000)
            h.peers={h.mine,'friend'}
            assert(h.identities.friend==nil)
            assert(a.push_ping({key='anonymous-peer',category='building',creator_id='friend'},1001))
            h.peers={h.mine}
            assert(a.poll(1005)==false and #h.sent==0,
                'unavailable name/color metadata must not allow a departed creator to remain queued')
        ''')

    def test_native_hex_creator_matches_full_uint64_session_id_without_float_rounding(self):
        self.run_lua('''
            local ffi=require('ffi')
            local id=ffi.new('uint64_t',0x0110000100000000)+0x22
            h.peers={h.mine,id}
            assert(a.set('ping',true)); a.record(1000)
            assert(a.push_ping({key='native',category='building',creator_id='0110000100000022'},1001))
            assert(a.push_ping({key='rounded',category='building',creator_id='0110000100000023'},1001)==false)
            h.peers={h.mine}; assert(a.poll(1005)==false and #h.sent==0)
        ''')

    def test_colored_prefix_resets_before_body_and_message_stays_within_native_limit(self):
        self.run_lua('''
            assert(a.set('ping',true)); assert(a.set('ping_message',string.rep('中',170)))
            h.identities.friend={peer_id='friend',name='Alice',short='A2',color='FF81ACFE'}
            assert(a.push_ping({key='long',category='building',creator_id='friend'},1000))
            assert(a.poll(1000))
            assert(h.sent[1]:sub(1,29)=='<c=FF81ACFE>[A2]<c=FFFFFFFF> ')
            assert(#h.sent[1]<=512 and #h.sent[1]:sub(30)%3==0)
        ''')

    def test_ping_category_preferences_are_independent_and_persisted(self):
        self.run_lua('''
            assert(a.set('ping', true))
            for _, key in ipairs({'ping_building','ping_stratagem','ping_map','ping_medium_enemy','ping_large_enemy',
                                  'ping_giant_enemy'}) do
                assert(a.options[key] == true)
                assert(a.set(key, false))
                local restored = h.new(h.writes[#h.writes])
                assert(restored.options[key] == false and restored.options.ping == true)
                assert(a.set(key, true))
            end
            assert(a.set('ping_message', '队友标记了{类别}，请注意！'))
            local restored = h.new(h.writes[#h.writes])
            assert(restored.options.ping_message == '队友标记了{类别}，请注意！')
            assert(a.set('ping_unknown', true) == false)
        ''')

    def test_classified_ping_uses_category_mask_template_and_shared_cooldown(self):
        self.run_lua('''
            assert(a.set('ping', true))
            assert(a.set('ping_message', '{类别}：{目标}'))
            assert(a.push_ping({key='1',category='large_enemy',target='重型目标'},1000))
            assert(a.poll(1000))
            assert(h.sent[1] == '大型敌人：重型目标')
            assert(a.push_ping({key='1',category='large_enemy',target='重型目标'},1000) == false)
            assert(a.set('ping_medium_enemy',false))
            assert(a.push_ping({key='2',category='medium_enemy'},1001) == false)
            assert(a.push_ping({key='3',category='giant_enemy'},1001))
            assert(a.poll(1001) == false and #h.sent == 1)
            assert(a.poll(1005) and #h.sent == 2)
            assert(h.sent[2] == '巨型敌人：巨型敌人')
            assert(a.push_ping({key='4',category='unknown'},1006) == false)
        ''')

    def test_ping_waits_for_chat_and_drops_stale_or_disabled_categories(self):
        self.run_lua('''
            assert(a.set('ping',true))
            h.send_ok=false
            assert(a.push_ping({key='1',category='building'},1000))
            assert(a.poll(1000) == false)
            h.send_ok=true
            assert(a.poll(1001) == false)
            assert(a.poll(1005))
            assert(a.push_ping({key='2',category='large_enemy'},1006))
            assert(a.set('ping_large_enemy',false))
            assert(a.poll(1010) == false and #h.sent == 2)
            assert(a.push_ping({key='3',category='giant_enemy'},1011))
            assert(a.poll(1030) == false and #h.sent == 2)
        ''')

    def test_ping_from_previous_lobby_is_never_sent_in_new_lobby(self):
        self.run_lua('''
            assert(a.set('ping',true))
            assert(a.push_ping({key='1',category='large_enemy'},1000))
            h.session='session-b'
            assert(a.poll(1000) == false and #h.sent == 0)
        ''')

    def test_host_and_client_are_distinct_boolean_states(self):
        self.run_lua("""
            assert(a.snapshot().is_host == true and a.check(0, 0))
            h.host = '76561198000000002'; h.peers[2] = h.host
            assert(a.snapshot().is_host == false)
            local ok = a.check(0, 1)
            assert(ok == true)
            h.host = 'not-present'
            assert(a.snapshot().is_host == nil)
            assert(a.push_ping({key='unconfirmed-role',category='stratagem'},1)==false)
        """)

    def test_ids_preserve_all_64_bits_and_remove_zero_duplicates(self):
        self.run_lua("""
            h.mine = '18446744073709551614'; h.host = h.mine
            h.peers = {h.mine, '18446744073709551615', h.mine, '0', 0, '0ULL', '0000'}
            local s = a.snapshot()
            assert(s.mine == h.mine and s.is_host == true)
            assert(#s.peers == 2 and #s.remote == 1)
            assert(s.remote[1] == '18446744073709551615')
            h.peers = {[h.mine] = true, ['18446744073709551615'] = true, ['0'] = true}
            assert(#a.snapshot().remote == 1)
        """)

    def test_no_welcome_for_initial_or_restarted_members(self):
        self.run_lua("""
            h.peers[2] = 'friend'; assert(a.set('welcome', true))
            a.poll(0); a.poll(20); assert(#h.sent == 0)
            h.a = h.new(h.writes[#h.writes]); a = h.a
            a.poll(30); a.poll(40); assert(#h.sent == 0)
        """)

    def test_raw_uint64_ids_and_sparse_peer_arrays(self):
        self.run_lua("""
            local ffi = require('ffi')
            local mine = ffi.new('uint64_t', 0x10000000) * 0x10000000 + 1
            local friend = mine + 1
            h.mine = mine; h.host = mine
            h.peers = {[1] = mine, [4] = friend, [7] = ffi.new('uint64_t', 0)}
            local s = a.snapshot()
            assert(s.mine == tostring(mine) and s.is_host == true)
            assert(#s.peers == 2 and s.remote[1] == tostring(friend))
        """)

    def test_throwing_and_partial_session_api_resets_pending(self):
        self.run_lua("""
            assert(a.set('welcome', true)); a.poll(0)
            h.peers[2] = 'friend'; a.poll(1)
            local peers = h.sr.GameSession.peers
            h.sr.GameSession.peers = function() error('transition') end
            assert(a.snapshot() == nil); a.poll(2)
            h.sr.GameSession.peers = peers; a.poll(3); a.poll(10)
            assert(#h.sent == 0)
            h.peers[1] = nil; assert(a.snapshot() == nil)
        """)

    def test_same_count_replacement_is_join_and_delay_is_observed(self):
        self.run_lua("""
            h.peers[2] = 'old'; assert(a.set('welcome', true)); a.poll(0)
            h.peers[2] = 'new'; a.poll(1); a.poll(2.9); assert(#h.sent == 0)
            a.poll(3); assert(#h.sent == 1 and h.sent[1] == a.options.welcome_message)
            a.poll(9); assert(#h.sent == 1)
        """)

    def test_leave_cancels_queued_welcome(self):
        self.run_lua("""
            assert(a.set('welcome', true)); a.poll(0)
            h.peers[2] = 'friend'; a.poll(1)
            h.peers[2] = nil; a.poll(2); a.poll(10); assert(#h.sent == 0)
        """)

    def test_session_local_host_and_context_changes_reset_baseline(self):
        for change in ["h.session = 'session-b'", "h.context = 'context-b'",
                       "h.mine = 'new-local'; h.peers[1] = h.mine; h.host = h.mine",
                       "h.host = 'new-host'; h.peers[3] = h.host"]:
            with self.subTest(change=change):
                self.setUp()
                self.run_lua("""
                    assert(a.set('welcome', true)); a.poll(0)
                    h.peers[2] = 'friend'; a.poll(1)
                """ + change + """; a.poll(2); a.poll(10); assert(#h.sent == 0)""")

    def test_invalid_session_resets_baseline(self):
        self.run_lua("""
            assert(a.set('welcome', true)); a.poll(0)
            h.peers[2] = 'friend'; a.poll(1)
            h.in_session = false; a.poll(2)
            h.in_session = true; a.poll(3); a.poll(10); assert(#h.sent == 0)
        """)

    def test_enabling_welcome_or_master_does_not_welcome_existing_members(self):
        self.run_lua("""
            a.poll(0); h.peers[2] = 'already-here'; a.poll(1)
            assert(a.set('welcome', true)); a.poll(2); a.poll(10)
            assert(#h.sent == 0)
            assert(a.set('enabled', false)); h.peers[3] = 'also-here'; a.poll(11)
            assert(a.set('enabled', true)); a.poll(12); a.poll(20)
            assert(#h.sent == 0)
        """)

    def test_legacy_host_scope_does_not_block_role_specific_client_welcome(self):
        self.run_lua("""
            h.host = 'host'; h.peers[2] = 'host'
            local b=h.new('client.scope=host\\n')
            assert(b.set('welcome',true,'client'))
            assert(b.sync()=='client')
            b.poll(0)
            h.peers[3] = 'friend'; b.poll(1); assert(#h.sent == 0)
            b.poll(3); assert(h.local_sent and #h.local_sent == 1)
        """)

    def test_master_solo_and_shared_cooldown_policy(self):
        self.run_lua("""
            assert(a.check(0, 0)); assert(a.set('allow_solo', false))
            assert(a.check(0, 0) == false and a.check(0, 1))
            a.record(10); assert(a.check(14.99, 1) == false and a.check(15, 1))
            assert(a.set('enabled', false)); assert(a.check(99, 1) == false)
            assert(a.set('enabled', true)); assert(a.set('cooldown', 0))
            assert(a.check(10, 1))
        """)

    def test_multiple_joins_have_independent_cooldowns_and_each_get_a_named_welcome(self):
        self.run_lua("""
            assert(a.set('welcome', true)); a.poll(0)
            assert(a.set('welcome_message','欢迎 {玩家名}（{缩写}，{编号}号）'))
            for i,key in ipairs({'one','two','three'}) do
                h.peers[i+1]=key
                h.identities[key]={peer_id=key,name=key,short='P'..(i+1),color_index=i}
            end
            a.poll(1); a.poll(3); a.poll(3); a.poll(3)
            assert(#h.sent==3 and next(a.state.pending)==nil)
            local lines=table.concat(h.sent,'|')
            assert(lines:find('欢迎 one（P2，2号）',1,true))
            assert(lines:find('欢迎 two（P3，3号）',1,true))
            assert(lines:find('欢迎 three（P4，4号）',1,true))
        """)

    def test_failed_chat_send_retains_welcome_and_waits_five_seconds(self):
        self.run_lua("""
            assert(a.set('welcome', true)); a.poll(0)
            h.peers[2] = 'friend'; a.poll(1); h.send_ok = false
            a.poll(3); assert(#h.sent == 1)
            h.send_ok = true; a.poll(7.99); assert(#h.sent == 1)
            a.poll(8); assert(#h.sent == 2)
            assert(a.check(12.99, 1, 'friend') == false and a.check(13, 1, 'friend'))
        """)

    def test_cooling_player_does_not_block_another_players_ping_behind_it(self):
        self.run_lua('''
            h.peers={h.mine,'A','B'}
            assert(a.set('ping',true)); assert(a.set('ping_sender_prefix',false))
            assert(a.set('ping_message','{目标}'))
            assert(a.push_ping({key='a1',category='map',creator_id='A',target='A1'},1000))
            assert(a.poll(1000))
            assert(a.push_ping({key='a2',category='map',creator_id='A',target='A2'},1001))
            assert(a.push_ping({key='b1',category='map',creator_id='B',target='B1'},1001))
            assert(a.poll(1001)); assert(h.sent[2]=='B1')
            assert(a.poll(1004)==false); assert(a.poll(1005)); assert(h.sent[3]=='A2')
        ''')

    def test_welcome_and_ping_share_only_the_trigger_players_limit(self):
        self.run_lua('''
            assert(a.set('welcome',true)); assert(a.set('ping',true)); a.poll(0)
            h.peers={h.mine,'A','B'}; a.poll(1); a.poll(3); a.poll(3)
            assert(#h.sent==2)
            assert(a.push_ping({key='a1',category='map',creator_id='A'},4))
            assert(a.poll(4)==false)
            assert(a.check(4,2), 'local task does not consume a remote player bucket')
            assert(a.poll(8)); assert(#h.sent==3)
        ''')

    def test_uint64_decimal_welcome_id_and_native_hex_ping_use_the_same_bucket(self):
        self.run_lua('''
            local ffi=require('ffi');local id=ffi.new('uint64_t',0x0110000100000000)+0x22
            h.peers={h.mine,id}
            a.record(1000,tostring(id))
            assert(a.check(1001,1), 'local player has an independent bucket')
            assert(a.check(1001,1,'0110000100000022')==false)
            assert(a.check(1005,1,'0110000100000022'))
        ''')

    def test_per_player_limits_reset_on_room_change_and_remove_departed_ids(self):
        self.run_lua('''
            h.peers={h.mine,'A','B'}; a.record(1000,'A'); a.record(1000,'B')
            assert(a.check(1001,2,'A')==false)
            h.peers={h.mine,'B'}; a.check(1001,1)
            h.peers={h.mine,'A','B'}
            assert(a.check(1001,2,'A') and a.check(1001,2,'B')==false)
            h.session='session-b'; h.peers={h.mine,'A','B'}
            assert(a.check(1001,2,'A') and a.check(1001,2,'B'))
        ''')

    def test_player_template_variables_are_literal_utf8_safe_and_have_clear_fallbacks(self):
        self.run_lua('''
            h.identities.friend={peer_id='friend',name='张三%{编号}<tag>',short='Z2',color_index=1}
            assert(a.format('{玩家名}|{名字}|{触发者}|{缩写}|{编号}|{未知}', 'friend')==
                '张三%{编号}tag|张三%{编号}tag|张三%{编号}tag|Z2|2|{未知}')
            assert(a.format('{玩家名}/{缩写}/{编号}','missing')=='队友/队友/?')
            assert(#a.format(string.rep('中',200),'friend')<=512)
        ''')

    def test_welcome_resolves_native_profile_from_session_uint64_without_guessing_slot(self):
        self.run_lua('''
            local ffi=require('ffi');local id=ffi.new('uint64_t',0x0110000100000000)+0x22
            h.identities['0110000100000022']={peer_id='0110000100000022',name='Alice',short='A3',color_index=2}
            assert(a.set('welcome',true));assert(a.set('welcome_message','欢迎 {玩家名} {缩写} {编号}'));a.poll(0)
            h.peers={h.mine,id};a.poll(1);assert(a.poll(3))
            assert(h.sent[1]=='欢迎 Alice A3 3')
        ''')

    def test_recently_welcomed_rejoining_peer_does_not_hold_up_a_newcomer(self):
        self.run_lua('''
            assert(a.set('welcome',true));a.poll(0)
            h.peers={h.mine,'A','B'};a.poll(1)
            a.record(2,'A')
            assert(a.poll(3)); assert(a.state.pending.B==nil and a.state.pending.A)
            assert(a.poll(3)==false);assert(a.poll(7));assert(next(a.state.pending)==nil)
        ''')

    def test_options_roundtrip_percent_newlines_and_never_execute_settings(self):
        self.run_lua("""
            local text = '你好%\\n欢迎=加入|小队'
            assert(a.set('welcome_message', text))
            local saved = h.writes[#h.writes]
            assert(not saved:find(text, 1, true))
            local b = h.new(saved); assert(b.options.welcome_message == text)
            local c = h.new("enabled=false\\nscope=host\\ncooldown=17\\nwelcome=true\\n" ..
                "welcome_delay=4\\nallow_solo=false\\nunknown=os.execute('bad')\\n")
            assert(not c.options.enabled and c.options.scope == nil and c.options.cooldown == 17)
            assert(c.options.welcome_delay == 4 and c.options.welcome and not c.options.allow_solo)
            assert(h.new('cooldown=bad\\nscope=bad\\nenabled=maybe\\n').options.cooldown == 5)
        """)

    def test_invalid_options_and_persistence_failure_leave_config_unchanged(self):
        self.run_lua("""
            for _, pair in ipairs({{'scope','client'}, {'cooldown',-1}, {'cooldown',3601},
                {'cooldown',1.5}, {'welcome_delay',61}, {'enabled','true'},
                {'welcome_message',''}, {'unknown',true}}) do
                local ok, why = a.set(pair[1], pair[2])
                assert(ok == false and type(why) == 'string' and #why > 0)
            end
            assert(#h.writes == 0)
            h.write_ok = false; assert(a.set('cooldown', 15) == false)
            assert(a.options.cooldown == 5)
            h.write_ok = true; h.throw_write = true
            assert(a.set('welcome', true) == false and not a.options.welcome)
        """)

    def test_failed_setting_save_preserves_queued_welcome(self):
        self.run_lua("""
            assert(a.set('welcome', true)); a.poll(0)
            h.peers[2] = 'friend'; a.poll(1)
            h.write_ok = false
            assert(a.set('welcome', false) == false and a.options.welcome == true)
            a.poll(3); assert(#h.sent == 1)
        """)


if __name__ == '__main__':
    unittest.main()
