"""Exercise the dedicated editors through real retained GUI hit regions."""
from pathlib import Path
import unittest
from lupa.luajit21 import LuaRuntime
import test_role_output as harness

ALERT_PANEL_FRAGMENT = Path(harness.SOURCE).with_name('alert_panel.lua')

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

    def render_fragment(self, panel, rows, chinese=False):
        lua=LuaRuntime(unpack_returned_tuples=True)
        draw=lua.execute(ALERT_PANEL_FRAGMENT.read_text(encoding='utf-8')+'\nreturn draw_alert_panel')
        lua.execute('''
            drawn_text,drawn_regions={},{}
            local C={PANEL='panel',LINE='line',YELLOW='yellow',ROW_HI='row_hi',ROW='row',
                LINE2='line2',TEXT='text',DIM='dim',FIELD='field',MUTED='muted',INK='ink'}
            canvas={palette=C}
            canvas.text=function(value,...)drawn_text[#drawn_text+1]=tostring(value)end
            canvas.rect=function(...)end;canvas.border=function(...)end;canvas.icon=function(...)end
            canvas.region=function(key,x,y,w,h)drawn_regions[#drawn_regions+1]={key=key,x=x,y=y,w=w,h=h}end
        ''')
        lua_rows=lua.table()
        for i,row in enumerate(rows,1):lua_rows[i]=lua.table_from(row)
        catalog=lua.table_from({'state':lua.table_from({'status':'fixture'}),
            'list_rules':lambda:lua_rows,'list':lambda:lua_rows})
        automation=lua.eval('''function()
            local a={state={active_role='host'}}
            function a.profile(role)return {output='squad',enabled=true,ping=true}end
            function a.rule(kind,id,role)return {}end
            return a
        end''')()
        p=lua.table_from(panel)
        draw(lua.globals().canvas,p,automation,catalog,chinese,'1.0.0',lua.eval('function(v)return v end'))
        keys={str(lua.globals().drawn_regions[i].key)
              for i in range(1,len(lua.globals().drawn_regions)+1)}
        labels=[str(lua.globals().drawn_text[i]) for i in range(1,len(lua.globals().drawn_text)+1)]
        return lua,p,draw,automation,catalog,keys,labels

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

    def test_batch_field_editor_uses_all_current_filter_matches_and_disables_empty_actions(self):
        lua,h,m=self.fixture();self.click(lua,h,m,'rules:open:stratagem')
        self.click(lua,h,m,'rules:filter:red')
        self.commit(lua,h,m,'rules:search','EAGLE')
        lua.execute('''batch_labels={}
            stingray.Gui.text=function(gui,value,...)
                batch_labels[#batch_labels+1]=tostring(value)
            end''')
        self.click(lua,h,m,'rules:batch:open')
        p=m.debug_panel()
        keys={p.regions[i].key for i in range(1,len(p.regions)+1)}
        self.assertTrue({'rules:batch:edit:cooldown','rules:batch:edit:mark_message',
                         'rules:batch:edit:call_message','rules:batch:apply:cooldown',
                         'rules:batch:reset:cooldown'} <= keys)
        self.assertTrue(any('1' in str(lua.globals().batch_labels[i])
                            for i in range(1,len(lua.globals().batch_labels)+1)))
        self.commit(lua,h,m,'rules:search','no-such-stratagem')
        p=m.debug_panel()
        keys={p.regions[i].key for i in range(1,len(p.regions)+1)}
        self.assertIn('rules:batch:edit:cooldown',keys,
                      'an empty result may keep editing a draft, but cannot apply it')
        self.assertNotIn('rules:batch:apply:cooldown',keys)
        self.assertNotIn('rules:batch:reset:cooldown',keys)

    def test_batch_apply_and_reset_cover_all_filtered_pages_and_preserve_other_fields(self):
        lua,h,m=self.fixture()
        lua.execute('''local c=m.debug_stratagem_catalog();local rows={}
            for i=1,12 do rows[i]={id=1000+i,name='Red '..i,debug_name='RED.ITEM.'..i,
                group='red',cooldown=30+i} end
            rows[13]={id=2001,name='Blue item',debug_name='BLUE.ITEM',group='blue',cooldown=90}
            c.list_rules=function()return rows end;c.list=function()return rows end''')
        self.click(lua,h,m,'rules:open:stratagem')
        self.click(lua,h,m,'rules:filter:red')
        self.click(lua,h,m,'rules:next')
        self.assertEqual(2,m.debug_panel().rule_page)
        a=m.debug_automation()
        self.assertTrue(a.set_rule('stratagem',1001,'call_message','preserve this field','host')[0])
        self.assertTrue(a.set_rule('stratagem',2001,'cooldown',90,'host')[0])
        self.click(lua,h,m,'rules:batch:open')
        self.commit(lua,h,m,'rules:batch:edit:cooldown','0')
        self.click(lua,h,m,'rules:batch:apply:cooldown')
        for rule_id in range(1001,1013):
            self.assertEqual(0,a.rule('stratagem',rule_id,'host').cooldown,rule_id)
        self.assertEqual(90,a.rule('stratagem',2001,'host').cooldown)
        self.assertEqual('preserve this field',a.rule('stratagem',1001,'host').call_message)
        self.click(lua,h,m,'rules:batch:reset:cooldown')
        for rule_id in range(1001,1013):
            self.assertIsNone(a.rule('stratagem',rule_id,'host').cooldown,rule_id)
        self.assertEqual('preserve this field',a.rule('stratagem',1001,'host').call_message)

    def test_batch_fragment_limits_actions_to_nonempty_filtered_matches_across_pages(self):
        rows=[
            {'id':4119049995,'name':'500千克炸弹','debug_name':'EAGLE.500KG','group':'red','cooldown':15},
            {'id':2902516083,'name':'轨道凝固汽油弹幕','debug_name':'ORBITAL.NAPALM','group':'red','cooldown':120},
            {'id':867876502,'name':'重新补给','debug_name':'CONSUMABLES.RESUPPLY','group':'blue','cooldown':180},
        ]
        panel={'profile':'host','rule_view':'stratagem','rule_filter':'red','rule_search':'EAGLE',
               'rule_batch_edit':True,'rule_page':1,'rule_selected':4119049995}
        lua,p,draw,automation,catalog,keys,labels=self.render_fragment(panel,rows,chinese=False)
        self.assertTrue({'rules:batch:edit:cooldown','rules:batch:edit:mark_message',
                         'rules:batch:edit:call_message','rules:batch:apply:cooldown',
                         'rules:batch:reset:cooldown'} <= keys)
        self.assertIn('APPLY TO FILTER (1)',labels)
        self.assertIn('RESET DEFAULT (1)',labels)
        p.rule_search='no-matching-target'
        lua.execute('drawn_regions,drawn_text={},{}')
        draw(lua.globals().canvas,p,automation,catalog,False,'1.0.0',lua.eval('function(v)return v end'))
        empty_keys={str(lua.globals().drawn_regions[i].key)
                    for i in range(1,len(lua.globals().drawn_regions)+1)}
        self.assertIn('rules:batch:edit:cooldown',empty_keys)
        self.assertNotIn('rules:batch:apply:cooldown',empty_keys)
        self.assertNotIn('rules:batch:reset:cooldown',empty_keys)

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
            ok,why=a.set('message_language','auto');assert(ok,why)
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
