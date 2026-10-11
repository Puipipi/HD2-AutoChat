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

    def render_fragment(self, panel, rows, chinese=False, native_localize=None,
                       game_locale='zh', panel_locale='zh'):
        lua=LuaRuntime(unpack_returned_tuples=True)
        lua.execute('M={}')
        draw,pump=lua.execute(ALERT_PANEL_FRAGMENT.read_text(encoding='utf-8')+'\nreturn draw_alert_panel,M.pump_alert_panel_native_names')
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
        for i,row in enumerate(rows,1):
            converted=dict(row)
            for key,value in tuple(converted.items()):
                if isinstance(value,dict): converted[key]=lua.table_from(value)
            lua_rows[i]=lua.table_from(converted)
        lua.globals().FIXTURE_RULE_ROWS=lua_rows
        lua.execute('CATALOG_LIST_CALLS=0; RULE_CALLS=0')
        catalog=lua.table_from({'state':lua.table_from({'status':'fixture','generation':1})})
        catalog[b'list_rules']=lua.eval('function() CATALOG_LIST_CALLS=CATALOG_LIST_CALLS+1; return FIXTURE_RULE_ROWS end')
        catalog[b'list']=catalog[b'list_rules']
        if native_localize is not None:
            lua.globals().py_localizer=native_localize
            native_localize=lua.eval('function(key)return py_localizer(key)end')
        automation=lua.eval('''function()
            local a={state={active_role='host'}}
            function a.profile(role)return {output='squad',enabled=true,ping=true}end
            function a.rule(kind,id,role)RULE_CALLS=RULE_CALLS+1;return {enabled=(tonumber(id) or 0)%2==1}end
            return a
        end''')()
        p=lua.table_from(panel)
        draw(lua.globals().canvas,p,automation,catalog,chinese,'1.0.0',lua.eval('function(v)return v end'),
             native_localize,game_locale,panel_locale)
        keys={str(lua.globals().drawn_regions[i].key)
              for i in range(1,len(lua.globals().drawn_regions)+1)}
        labels=[str(lua.globals().drawn_text[i]) for i in range(1,len(lua.globals().drawn_text)+1)]
        return lua,p,draw,pump,automation,catalog,keys,labels

    def test_visible_names_use_existing_localizer_with_budget_and_language_gate(self):
        calls=[]
        def localize(key):
            calls.append(int(key))
            return {11:'Unknown stratagem',21:'本地化战备'} .get(int(key))
        rows=[{'id':123,'name_key':11,'name_upper_key':21,'native_name_missing':{'zh':True,'en':True},'display_name':'战备 #123',
               'display_name_en':'Stratagem #123','name':'FUTURE.ITEM','group':'other',
               'cooldown':0}]
        lua,p,draw,pump,automation,catalog,_,labels=self.render_fragment(
            {'open':True,'rule_view':'stratagem','rule_filter':'all'},rows,True,localize,'zh','zh')
        self.assertEqual([],calls,'retained draw must only register candidates, never localize')
        pump(p,lua.eval('function(key)return py_localizer(key)end'),'zh','zh',1,1)
        self.assertEqual(calls,[11,21])
        draw(lua.globals().canvas,p,automation,catalog,True,'1.0.0',lua.eval('function(v)return v end'),
             lua.eval('function(key)return py_localizer(key)end'),'zh','zh')
        labels=[str(lua.globals().drawn_text[i]) for i in range(1,len(lua.globals().drawn_text)+1)]
        self.assertIn('本地化战备',labels)
        calls.clear();redraws=[]
        lua.globals().py_redraw=lambda:redraws.append('redraw')
        self.assertEqual(0,pump(p,lua.eval('function(key)return py_localizer(key)end'),
                                'zh','zh',1,2,lua.eval('function()py_redraw()end')))
        self.assertEqual([],calls)
        self.assertEqual([],redraws,'completed names must not poll or dirty retained UI')
        p.open=False
        self.assertEqual(0,pump(p,lua.eval('function(key)return py_localizer(key)end'),
                                'zh','zh',1,3,lua.eval('function()py_redraw()end')))
        self.assertEqual([],calls,'closed panel must not enter the native resolver')
        # A different preview locale must not display the game's other-language
        # string or invoke native localization for the panel.
        calls.clear()
        _,_,_,_,_,_,_,labels=self.render_fragment({'rule_view':'stratagem','rule_filter':'all'},rows,False,
                                                  localize,'zh','en')
        self.assertEqual(calls,[])
        self.assertIn('Stratagem #123',labels)
        for english_alias in ('{player_name}', '{abbr} / {slot}', '{target}', '{stratagem}',
                              '{category}', '{action}', '{objective}', '{objective_type}', '{position}'):
            self.assertIn(english_alias, labels)
        self.assertNotIn('{玩家名}/{player_name}', labels)

    def test_stratagem_draw_uses_one_catalog_pass_and_preserves_group_counts(self):
        rows=[
            {'id':11,'name':'Red enabled','debug_name':'RED.ONE','group':'red','cooldown':1},
            {'id':12,'name':'Red disabled','debug_name':'RED.TWO','group':'red','cooldown':1},
            {'id':21,'name':'Blue enabled','debug_name':'BLUE.ONE','group':'blue','cooldown':1},
            {'id':31,'name':'Green enabled','debug_name':'GREEN.ONE','group':'green','cooldown':1},
            {'id':41,'name':'Mission enabled','debug_name':'MISSION.ONE','group':'other','family':'mission','cooldown':1},
            {'id':42,'name':'Mission disabled','debug_name':'MISSION.TWO','group':'other','family':'mission','cooldown':1},
            {'id':51,'name':'Other','debug_name':'OTHER.ONE','group':'other','cooldown':1},]
        lua,p,draw,pump,automation,catalog,keys,labels=self.render_fragment(
            {'open':True,'rule_view':'stratagem','rule_filter':'all'},rows,False)
        self.assertEqual(1,int(lua.globals().CATALOG_LIST_CALLS),
                         'the production draw should fetch the rules list once')
        self.assertLessEqual(int(lua.globals().RULE_CALLS),len(rows)+1,
                             'group counts, visible rows and details should reuse per-row rule values')
        for label in ('RED 1/2','BLUE 1/1','GREEN 1/1','MISSION STRATAGEMS 1/2'):
            self.assertIn(label,labels)

    def test_native_name_lookup_is_budgeted_and_nil_can_recover_next_frame(self):
        calls=[];ready={'value':False}
        def localize(key):
            calls.append(int(key))
            return '恢复后的战备' if ready['value'] and int(key)==11 else None
        rows=[{'id':123,'name_key':11,'name_upper_key':21,'native_name_missing':{'zh':True,'en':True},'display_name':'战备 #123',
               'display_name_en':'Stratagem #123','name':'FUTURE.ITEM','group':'other',
               'cooldown':0}]
        lua,p,draw,pump,automation,catalog,_,labels=self.render_fragment(
            {'open':True,'rule_view':'stratagem','rule_filter':'all'},rows,True,localize,'zh','zh')
        pump(p,lua.eval('function(key)return py_localizer(key)end'),'zh','zh',1,601)
        self.assertLessEqual(len(calls),4)
        self.assertNotIn('恢复后的战备',labels)
        self.assertEqual(616,p._native_name_retry_frame)
        ready['value']=True;calls.clear()
        pump(p,lua.eval('function(key)return py_localizer(key)end'),'zh','zh',1,616)
        self.assertIn(11,calls,'nil lookup was incorrectly cached as permanently missing')
        self.assertLessEqual(len(calls),4)
        draw(lua.globals().canvas,p,automation,catalog,True,'1.0.0',
             lua.eval('function(v)return v end'),lua.eval('function(key)return py_localizer(key)end'),'zh','zh')
        labels=[str(lua.globals().drawn_text[i]) for i in range(1,len(lua.globals().drawn_text)+1)]
        self.assertIn('恢复后的战备',labels,'a recovered name must become the rendered UI label')

    def test_native_pump_round_robins_past_persistently_nil_rows(self):
        calls=[];dirty=[];target={'key':None}
        def localize(key):
            calls.append(int(key))
            return '第三候选已本地化' if int(key)==target['key'] else None
        rows=[]
        for index in range(1,4):
            rows.append({'id':100+index,'name_key':100+index,'name_upper_key':200+index,
                'native_name_missing':{'zh':True,'en':True},'display_name':'战备 #'+str(100+index),
                'display_name_en':'Stratagem #'+str(100+index),'name':'FUTURE.ITEM.'+str(index),
                'group':'other','cooldown':0})
        lua,p,draw,pump,automation,catalog,_,labels=self.render_fragment(
            {'open':True,'rule_view':'stratagem','rule_filter':'all'},rows,True,localize,'zh','zh')
        localized=lua.eval('function(key)return py_localizer(key)end')
        self.assertEqual([],calls)
        candidate_ids=[int(p._native_name_candidates[i].id) for i in range(1,len(p._native_name_candidates)+1)]
        self.assertGreaterEqual(len(candidate_ids),3,candidate_ids)
        first=pump(p,localized,'zh','zh',1,1,lambda:dirty.append('redraw'))
        self.assertLessEqual(first,4)
        candidate_ids=[int(p._native_name_candidates[i].id) for i in range(1,len(p._native_name_candidates)+1)]
        self.assertGreaterEqual(len(candidate_ids),3,candidate_ids)
        target['key']=int(p._native_name_candidates[3].name_key)
        expected=[]
        for index in range(1,3):
            row=p._native_name_candidates[index]
            expected.extend([int(row.name_key),int(row.name_upper_key)])
        self.assertEqual(expected,calls)
        self.assertEqual([],dirty)
        self.assertEqual(3,p._native_name_cursor,'the next pump must begin after the two nil rows')
        lua.globals().py_redraw=lambda:dirty.append('redraw')
        redraw=lua.eval('function()py_redraw()end')
        second=pump(p,localized,'zh','zh',1,16,redraw)
        self.assertLessEqual(second,4)
        self.assertIn(target['key'],calls)
        self.assertEqual(['redraw'],dirty,'only a changed rendered name dirties the retained GUI')
        draw(lua.globals().canvas,p,automation,catalog,True,'1.0.0',lua.eval('function(v)return v end'),
             localized,'zh','zh')
        labels=[str(lua.globals().drawn_text[i]) for i in range(1,len(lua.globals().drawn_text)+1)]
        self.assertIn('第三候选已本地化',labels)
        before=len(calls)
        dirty_before=len(dirty)
        self.assertEqual(0,pump(p,localized,'zh','zh',1,17,redraw))
        self.assertEqual(before,len(calls),'cached visible names must stay native-call free')
        self.assertEqual(dirty_before,len(dirty),'cached visible names must not request another redraw')

    def test_locale_or_catalog_change_invalidates_candidates_before_native_lookup(self):
        calls=[];redraws=[]
        def localize(key):
            calls.append(int(key));return '新目录名称'
        rows=[{'id':123,'name_key':11,'name_upper_key':21,'native_name_missing':{'zh':True,'en':True},
               'display_name':'战备 #123','display_name_en':'Stratagem #123','name':'FUTURE.ITEM',
               'group':'other','cooldown':0}]
        lua,p,draw,pump,automation,catalog,_,_=self.render_fragment(
            {'open':True,'rule_view':'stratagem','rule_filter':'all'},rows,True,localize,'zh','zh')
        localized=lua.eval('function(key)return py_localizer(key)end')
        lua.globals().py_redraw=lambda:redraws.append('redraw')
        redraw=lua.eval('function()py_redraw()end')
        self.assertEqual(0,pump(p,localized,'zh','zh',2,1,redraw))
        self.assertEqual([],calls,'stale candidate generations must not be queried')
        self.assertEqual(0,len(p._native_name_retry_by_key or {}))
        self.assertEqual(0,len(p._native_name_key_cursor or {}))
        self.assertEqual(0,len(p._native_name_fallbacks or {}))
        self.assertEqual(['redraw'],redraws)
        self.assertEqual(0,pump(p,localized,'zh','zh',2,2,redraw))
        self.assertEqual(['redraw'],redraws,'request one registration draw per new cache key')
        catalog.state.generation=2
        draw(lua.globals().canvas,p,automation,catalog,True,'1.0.0',lua.eval('function(v)return v end'),
             localized,'zh','zh')
        self.assertGreater(pump(p,localized,'zh','zh',2,3,redraw),0)
        self.assertGreater(len(calls),0)

    def test_auto_chat_production_panel_frame_pumps_without_failure_redraw(self):
        lua,h,m=self.fixture()
        lua.execute('''local c=m.debug_stratagem_catalog();local rows={
            {id=701,name='战备 #701',display_name='战备 #701',display_name_en='Stratagem #701',
             name='FUTURE.ONE',name_key=701,name_upper_key=1701,native_name_missing={zh=true,en=true},
             group='other',cooldown=0},
            {id=702,name='战备 #702',display_name='战备 #702',display_name_en='Stratagem #702',
             name='FUTURE.TWO',name_key=702,name_upper_key=1702,native_name_missing={zh=true,en=true},
             group='other',cooldown=0},
            {id=703,name='战备 #703',display_name='战备 #703',display_name_en='Stratagem #703',
             name='FUTURE.THREE',name_key=703,name_upper_key=1703,native_name_missing={zh=true,en=true},
             group='other',cooldown=0}}
            c.list=function()return rows end;c.list_rules=c.list;c.state.generation=987
            panel_texts={};stingray.Gui.text=function(gui,value,...)
                panel_texts[#panel_texts+1]=tostring(value)
            end
            lookup_calls={};ready_localization=false
            m.debug_localization().lookup=function(key)
                lookup_calls[#lookup_calls+1]=key
                if ready_localization and key==703 then return '生产路径名称' end
            end''')
        self.click(lua,h,m,'rules:open:stratagem')
        self.assertEqual('stratagem',m.debug_panel().rule_view)
        lua.execute('for i=1,4 do update() end')
        self.assertGreater(len(lua.globals().lookup_calls),0)
        panel=m.debug_panel();version=panel.version;sig=m.debug_panel_signature()
        lua.execute('lookup_calls={}')
        lua.eval('update()')
        self.assertEqual(0,len(lua.globals().lookup_calls),
                         'failed lookups must wait for their bounded retry deadline')
        self.assertEqual(version,panel.version,'nil lookup must not dirty/redraw the panel')
        self.assertEqual(sig,m.debug_panel_signature())
        lua.execute('ready_localization=true; lookup_calls={}; for i=1,20 do update() end')
        labels=[str(lua.globals().panel_texts[i]) for i in range(1,len(lua.globals().panel_texts)+1)]
        self.assertIn('[Chinese text hidden]',labels,
                      'English production draw must hide CJK native labels without dropping the row')
        row=m.debug_stratagem_catalog().list()[3]
        self.assertEqual('生产路径名称',row._panel_native_names['en:987'],
                         'drawing fallback must not overwrite the native localization cache')
        self.assertEqual(0,m.debug_panel_errors or 0)

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
        lua,p,draw,pump,automation,catalog,keys,labels=self.render_fragment(panel,rows,chinese=False)
        self.assertTrue({'rules:batch:edit:cooldown','rules:batch:edit:mark_message',
                         'rules:batch:edit:call_message','rules:batch:apply:cooldown',
                         'rules:batch:reset:cooldown'} <= keys)
        self.assertIn('APPLY (1)',labels)
        self.assertIn('RESET (1)',labels)
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

    def test_non_han_non_ascii_native_name_does_not_replace_english_catalog_name(self):
        lua,h,m=self.fixture()
        lua.execute('''local c=m.debug_stratagem_catalog()
            c.lookup=function() return {id=4119049995,rule_id=4119049995,group='red',
                display_name='静态中文名',display_name_en='Static “English” Name',
                target_names={zh='静态中文名',en='Static “English” Name'}} end
            local event={category='stratagem',stratagem_id=4119049995,
                target_names={native_name='せんりゃく'}}
            m.debug_enrich_stratagem_event(event,1000)
            assert(event.target_names.zh=='静态中文名')
            assert(event.target_names.en=='Static “English” Name')
        ''')
