"""Behavioral checks for per-player, per-rule messages and cooldowns."""
import unittest
import test_chat_automation as harness


class AlertRuleTests(unittest.TestCase):
    setUp = harness.AutomationTests.setUp
    run_lua = harness.AutomationTests.run_lua
    def test_rule_profiles_roundtrip_and_save_failure(self):
        self.run_lua('''
            assert(a.set_rule('stratagem',4119049995,'enabled',false,'host'))
            assert(a.set_rule('stratagem',4119049995,'call_message','{缩写}扔了{目标}！','client'))
            assert(a.set_rule('enemy','flying_enemy','cooldown',0,'client'))
            local b=h.new(h.writes[#h.writes])
            assert(b.rule('stratagem',4119049995,'host').enabled==false)
            assert(b.rule('stratagem',4119049995,'client').call_message=='{缩写}扔了{目标}！')
            assert(b.rule('enemy','flying_enemy','client').cooldown==0)
            h.write_ok=false
            assert(not b.set_rule('stratagem',4119049995,'enabled',true,'host'))
            assert(b.rule('stratagem',4119049995,'host').enabled==false)
            assert(not b.set_rule('enemy','flying_enemy','cooldown',-1))
            assert(not b.set_rule('stratagem','bad','enabled',true))
        ''')

    def test_zero_cooldown_bypasses_global_and_blocked_ping_but_deduplicates(self):
        self.run_lua('''
            assert(a.set('ping',true));assert(a.set('cooldown',3600))
            assert(a.set_rule('stratagem',4119049995,'cooldown',0))
            assert(a.set_rule('stratagem',4119049995,'call_message','危险：{目标}'))
            a.record(1000)
            assert(a.push_ping({key='blocked',category='map',target='任务'},1001))
            local event={key='bomb1',category='stratagem',stratagem_id=4119049995,action='summon',target='500kg'}
            assert(a.push_ping(event,1001));assert(a.poll(1001));assert(h.sent[1]=='危险：500kg')
            assert(not a.push_ping(event,1001))
            event.key='bomb2';assert(a.push_ping(event,1001));assert(a.poll(1001))
            assert(#h.sent==2 and #a.state.pings==1)
            assert(not a.check(1001,1)) -- urgent sends did not remove global timer
        ''')

    def test_independent_rule_timer_per_player_and_other_rules(self):
        self.run_lua('''
            assert(a.set('message_language','zh'))
            h.peers={h.mine,'76561198000000002'}
            assert(a.set('ping',true));assert(a.set('cooldown',3600))
            assert(a.set_rule('enemy','medium_enemy','cooldown',10))
            assert(a.set_rule('enemy','medium_enemy','mark_message','{类别}:{目标}'))
            a.record(1000,h.mine)
            local e={key='m1',category='medium_enemy',target='武斗虫',creator_id=h.mine}
            assert(a.push_ping(e,1001));assert(a.poll(1001));assert(h.sent[1]:find('中型敌人:武斗虫',1,true))
            e.key='m2';assert(a.push_ping(e,1002));assert(not a.poll(1002))
            e.key='m3';e.creator_id=h.peers[2];assert(a.push_ping(e,1002));assert(a.poll(1002))
            assert(a.poll(1011));assert(#h.sent==3)
        ''')

    def test_disable_bulk_and_blank_inheritance_keep_default_template(self):
        self.run_lua('''
            assert(a.set('message_language','zh'))
            assert(a.set('ping',true));assert(a.set('cooldown',0))
            assert(a.set('ping_message','标记了{目标}（{类别}）'))
            assert(a.set_rules('stratagem',{1,2},false))
            assert(not a.push_ping({key='no',category='stratagem',stratagem_id=1},1000))
            assert(a.set_rule('stratagem',1,'enabled',true))
            assert(a.set_rule('stratagem',1,'mark_message','自定义'))
            assert(a.set_rule('stratagem',1,'mark_message',''))
            assert(a.push_ping({key='yes',category='stratagem',stratagem_id=1,target='重机枪'},1000))
            assert(a.poll(1000));assert(h.sent[1]=='标记了重机枪（战备提示）')
            assert(a.rule('stratagem',2).enabled==false)
            assert(a.set('enabled',false))
            assert(not a.push_ping({key='off',category='flying_enemy',target='炮艇'},1001))
        ''')

    def test_flying_is_independent_and_small_defaults_off(self):
        self.run_lua('''
            assert(a.set('ping',true));assert(a.set('ping_large_enemy',false))
            assert(a.push_ping({key='air',category='flying_enemy',target='炮艇'},1000))
            assert(not a.push_ping({key='small',category='small_enemy',target='清道夫'},1000))
            assert(a.set('ping_flying_enemy',false))
            assert(not a.push_ping({key='air2',category='flying_enemy'},1000))
        ''')

    def test_factory_has_no_zero_cooldown_rules_and_user_zero_survives_save(self):
        self.run_lua('''
            assert(a.rule('stratagem',4119049995).cooldown==nil)
            assert(a.rule('stratagem',2902516083,'client').cooldown==nil)
            assert(a.set_rule('stratagem',4119049995,'cooldown',0,'host'))
            assert(a.set_rule('stratagem',2902516083,'cooldown',0,'client'))
            local hp=a.export_profile('host');local cp=a.export_profile('client')
            local b=h.new();assert(b.import_profile(hp,'host'));assert(b.import_profile(cp,'client'))
            assert(b.rule('stratagem',4119049995,'host').cooldown==0)
            assert(b.rule('stratagem',2902516083,'client').cooldown==0)
            assert(a.set_rule('stratagem',4119049995,'cooldown',''))
            local cleared=a.export_profile('host');local c=h.new();assert(c.import_profile(cleared,'host'));assert(c.import_profile(cp,'client'))
            assert(c.rule('stratagem',4119049995,'host').cooldown==nil)
            assert(c.rule('stratagem',2902516083,'client').cooldown==0)
        ''')

    def test_urgent_alert_survives_full_blocked_queue_and_welcome(self):
        self.run_lua('''
            assert(a.set('message_language','zh'))
            assert(a.set('summon_message','{玩家名}召唤了{目标}'))
            assert(a.set('welcome_message','欢迎加入小队！'))
            assert(a.set('ping',true));assert(a.set('welcome',true));assert(a.set('welcome_delay',0))
            assert(a.set('cooldown',3600));a.poll(1000);a.record(1000)
            assert(a.set_rule('stratagem',4119049995,'cooldown',0))
            for i=1,16 do assert(a.push_ping({key='blocked'..i,category='map'},1001)) end
            h.peers={h.mine,'76561198000000002'}
            assert(a.push_ping({key='bomb',category='stratagem',stratagem_id=4119049995,action='summon',target='500kg'},1001))
            assert(a.poll(1001));assert(h.sent[1]=='队友召唤了500kg')
            assert(a.poll(1001));assert(h.sent[2]=='欢迎加入小队！')
        ''')
