"""Exercise the dedicated editors through real retained GUI hit regions."""
import unittest
import test_role_output as harness


class AlertPanelTests(unittest.TestCase):
    fresh = harness.RoleOutputTests.fresh
    click = harness.RoleOutputTests.click

    def fixture(self):
        lua,h,m=self.fresh()
        lua.execute('''
            local c=m.debug_stratagem_catalog()
            local rows={
                {id=4119049995,name='500千克炸弹',debug_name='EAGLE.500KG',group='red',icon='F96A659EBFFDFBE4',cooldown=15},
                {id=2902516083,name='轨道凝固汽油弹幕',debug_name='ORBITAL.NAPALM',group='red',cooldown=120},
                {id=867876502,name='重新补给',debug_name='CONSUMABLES.RESUPPLY',group='blue',cooldown=180,variant_ids={867876502,1295431756}},
                {id=3,name='机枪哨戒炮',debug_name='SENTRYS.MACHINEGUN',group='green',cooldown=180},
                {id=4,name='超级地球旗帜',debug_name='MISSIONS.RAISE FLAG',group='other',family='mission',cooldown=30},
                {id=5,name='上传数据',debug_name='MISSIONS.DATA JACK',group='other',family='mission',cooldown=30}}
            c.scan=function()return #rows,'fixture' end
            c.list=function()return rows end;c.list_rules=c.list
            c.state.ready=true;c.state.status='fixture'
            stingray.Gui.bitmap_uv=function(...) icon_calls=(icon_calls or 0)+1 end
        ''')
        self.click(lua,h,m,'view:pings')
        return lua,h,m

    def commit(self,lua,h,m,key,value):
        self.click(lua,h,m,key)
        m.debug_panel().edit_text=value
        h.user32.set_key(0x0D,True);lua.eval('update()')
        h.user32.set_key(0x0D,False);lua.eval('update()')

    def test_stratagem_editor_profiles_bulk_switches_and_fields(self):
        lua,h,m=self.fixture();self.click(lua,h,m,'rules:open:stratagem')
        self.assertEqual('stratagem',m.debug_panel().rule_view)
        self.click(lua,h,m,'profile:client')
        self.click(lua,h,m,'rules:bulk:red:off')
        a=m.debug_automation()
        self.assertFalse(a.rule('stratagem',4119049995,'client').enabled)
        self.assertFalse(a.rule('stratagem',2902516083,'client').enabled)
        self.assertIsNone(a.rule('stratagem',4119049995,'host').enabled)
        self.click(lua,h,m,'rules:enabled')
        self.assertTrue(a.rule('stratagem',4119049995,'client').enabled)
        self.commit(lua,h,m,'rule:stratagem:4119049995:call_message','{缩写}：小心{目标}！')
        self.commit(lua,h,m,'rule:stratagem:4119049995:cooldown','0')
        self.assertEqual('{缩写}：小心{目标}！',a.rule('stratagem',4119049995,'client').call_message)
        self.assertEqual(0,a.rule('stratagem',4119049995,'client').cooldown)
        self.commit(lua,h,m,'rule:stratagem:4119049995:cooldown','-1')
        self.assertEqual(0,a.rule('stratagem',4119049995,'client').cooldown)
        h.user32.set_key(0x1B,True);lua.eval('update()');h.user32.set_key(0x1B,False);lua.eval('update()')
        self.click(lua,h,m,'rules:inherit')
        self.assertIsNone(a.rule('stratagem',4119049995,'client').cooldown)
        self.assertIsNone(a.rule('stratagem',4119049995,'client').call_message)
        self.assertTrue(a.rule('stratagem',4119049995,'client').enabled)
        self.assertIsNone(m.draw_error_text)

    def test_task_stratagem_batch_controls_cover_only_catalog_mission_family(self):
        lua,h,m=self.fixture();self.click(lua,h,m,'rules:open:stratagem')
        a=m.debug_automation()
        self.assertTrue(a.set_rule('stratagem',4,'call_message','custom mission copy','host')[0])
        self.click(lua,h,m,'rules:bulk:mission:off')
        self.assertFalse(a.rule('stratagem',4,'host').enabled)
        self.assertFalse(a.rule('stratagem',5,'host').enabled)
        self.assertIsNone(a.rule('stratagem',4119049995,'host').enabled)
        self.assertIsNone(a.rule('stratagem',867876502,'host').enabled)
        self.assertIsNone(a.rule('stratagem',3,'host').enabled)
        self.assertEqual('custom mission copy',a.rule('stratagem',4,'host').call_message)
        self.click(lua,h,m,'rules:bulk:mission:on')
        self.assertTrue(a.rule('stratagem',4,'host').enabled)
        self.assertTrue(a.rule('stratagem',5,'host').enabled)

    def test_enemy_flying_controls_and_search_do_not_change_other_rules(self):
        lua,h,m=self.fixture();m.debug_language().update('zh',0);self.click(lua,h,m,'rules:open:enemy')
        self.click(lua,h,m,'rules:select:flying_enemy');self.click(lua,h,m,'rules:enabled')
        a=m.debug_automation();self.assertFalse(a.profile('host').ping_flying_enemy)
        self.assertTrue(a.profile('host').ping_large_enemy)
        self.commit(lua,h,m,'rule:enemy:flying_enemy:mark_message','天上：{目标}')
        self.assertEqual('天上：{目标}',a.rule('enemy','flying_enemy','host').mark_message)
        self.click(lua,h,m,'rules:back');self.click(lua,h,m,'rules:open:stratagem')
        self.commit(lua,h,m,'rules:search','凝固')
        self.assertEqual(2902516083,m.debug_panel().rule_selected)
        self.assertFalse(m.panel_errors)

    def test_icons_require_loaded_material_and_safe_hash(self):
        lua,h,m=self.fixture()
        lua.execute("stingray.Application.can_get=function(kind,id) return kind~='material' or tostring(id)~='F96A659EBFFDFBE4' end")
        self.click(lua,h,m,'rules:open:stratagem')
        self.assertIsNone(lua.globals().icon_calls)
        lua.execute("stingray.Application.can_get=function()return true end")
        self.click(lua,h,m,'rules:filter:red')
        self.assertGreater(lua.globals().icon_calls or 0,0)

    def test_ambiguous_actual_id_still_uses_shared_rule_without_faking_sender_variant(self):
        lua,h,m=self.fixture()
        self.click(lua,h,m,'rules:open:stratagem');self.click(lua,h,m,'rules:bulk:blue:off')
        lua.execute('''local c=m.debug_stratagem_catalog()
            c.resolve_rule_name_key=function(key)
                if key==1263463686 then return {id=867876502,group='blue'} end
            end
            local event={key='shared-resupply',category='stratagem',action='summon',
                localization_key=1263463686,target='重新补给'}
            m.debug_enrich_stratagem_event(event,1000)
            assert(event.stratagem_id==nil and event.stratagem_rule_id==867876502 and event.stratagem_ambiguous)
            local a=m.debug_automation();assert(a.set('ping',true))
            assert(a.rule('stratagem',867876502).enabled==false)
            assert(not a.push_ping(event,1000))
            assert(a.set_rule('stratagem',867876502,'enabled',true))
            assert(a.set_rule('stratagem',867876502,'call_message','{目标}投下来了'))
            assert(a.set_rule('stratagem',867876502,'cooldown',0))
            a.record(1000);assert(a.push_ping(event,1001))
            assert(a.state.pings[1].text=='重新补给投下来了' and a.state.pings[1].cooldown==0)
        ''')

    def test_catalog_display_name_reaches_ping_template_without_changing_identity(self):
        lua,h,m=self.fixture()
        m.debug_language().update('zh',0)
        lua.execute('''local c=m.debug_stratagem_catalog()
            c.lookup=function(id) if id==4119049995 then return {id=id,rule_id=id,group='red',display_name='五百千克炸弹'} end end
            local event={key='mapped',category='stratagem',action='summon',stratagem_id=4119049995,
                target='EAGLE.500KG'}
            m.debug_enrich_stratagem_event(event,1000)
            assert(event.stratagem_id==4119049995 and event.display_name=='五百千克炸弹','display enrichment missing')
            local a=m.debug_automation();local ok,why=a.set('ping',true);assert(ok,why)
            ok,why=a.set('ping_sender_prefix',false);assert(ok,why)
            ok,why=a.set('summon_message','{目标}');assert(ok,why)
            ok,why=a.push_ping(event,1000);assert(ok,why or a.state.status)
            assert(a.state.pings[1].text=='五百千克炸弹',a.state.pings[1].text)
            ok,why=a.set_rule('stratagem',4119049995,'call_message','{任务类型}');assert(ok,why)
            ok,why=a.set_rule('stratagem',4119049995,'cooldown',0);assert(ok,why)
            event.key='mapped-objective-zh';event.objective_kind='primary'
            ok,why=a.push_ping(event,1001);assert(ok,why or a.state.status)
            assert(a.state.pings[1].text=='主线任务',a.state.pings[1].text)
            m.debug_language().update('en',2)
            event.key='mapped-objective-en'
            ok,why=a.push_ping(event,1002);assert(ok,why or a.state.status)
            assert(a.state.pings[2].text=='PRIMARY OBJECTIVE',a.state.pings[2].text)
        ''')
