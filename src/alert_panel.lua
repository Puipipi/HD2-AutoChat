-- Dedicated configuration views using the existing Armory frame/input owner.
-- No native reads here; catalog rows and safely bound icons come from the host.
local function draw_alert_panel(canvas,p,a,catalog,chinese,version)
    local C=canvas.palette
    local function say(cn,en) return chinese and cn or en end
    local function text(v,x,y,size,c,w) canvas.text(v,x,y,size or 14,c or C.TEXT,w) end
    local function button(key,value,x,y,w,on)
        canvas.rect(x,y,w,32,on and C.YELLOW or p.hover==key and C.ROW_HI or C.PANEL,951)
        canvas.border(x,y,w,32,on and C.YELLOW or C.LINE2,952)
        text(value,x+9,y+8,13,on and C.INK or C.TEXT,w-18);canvas.region(key,x,y,w,32)
    end
    local role=p.profile or 'host';local opts=a.profile(role)
    button('profile:host',say('主机预设','HOST PRESET'),614,48,146,role=='host')
    button('profile:client',say('客机预设','CLIENT PRESET'),768,48,146,role=='client')
    text(say('输出：','OUTPUT: ')..(opts.output=='local' and say('仅自己可见','ONLY ME') or say('小队公屏','SQUAD CHAT')),
        614,86,12,C.YELLOW,300)
    button('rules:back',say('返回设置','BACK'),22,166,120,false)
    local enemy=p.rule_view=='enemy'
    text(enemy and say('敌人细分提醒','ENEMY ALERT RULES') or say('战备细分提醒','STRATAGEM ALERT RULES'),160,170,22,C.TEXT,750)
    text(say('自动消息：','AUTO MESSAGES: ')..(opts.enabled and opts.ping and 'ON' or 'OFF')..
        say('  · 空消息继承默认模板','  · BLANK MESSAGES INHERIT DEFAULTS'),22,210,12,C.MUTED,950)
    local rows={}
    if enemy then
        for _,v in ipairs({{'small_enemy','小型敌人','SMALL'}, {'medium_enemy','中型敌人','MEDIUM'},
            {'large_enemy','大型敌人','LARGE'}, {'giant_enemy','巨型敌人','MASSIVE'}, {'flying_enemy','飞行敌人','FLYING'}}) do
            rows[#rows+1]={id=v[1],name=say(v[2],v[3])}
        end
        text(say('飞行分类优先，不受原体型开关影响。','FLYING TAKES PRIORITY OVER SIZE.'),22,253,13,C.YELLOW,440)
        text(say('体型采用游戏内部 Small / Medium / Large / Massive。','SIZES FOLLOW THE GAME UNIT SIZE ENUM.'),22,278,12,C.MUTED,440)
        text(say('小型默认关闭；普通物资仍不提示。','SMALL IS OFF BY DEFAULT; NO ORDINARY SUPPLIES.'),22,303,12,C.MUTED,440)
    else
        local groups={{'red','红战备','RED'}, {'blue','蓝战备','BLUE'}, {'green','绿战备','GREEN'}}
        for i,v in ipairs(groups) do
            local y=237+(i-1)*38
            local total,enabled_count=0,0
            for _,row in ipairs(catalog.list_rules and catalog.list_rules() or catalog.list()) do
                if row.group==v[1] then
                    total=total+1
                    if a.rule('stratagem',row.id,role).enabled~=false then enabled_count=enabled_count+1 end
                end
            end
            text(say(v[2],v[3])..' '..enabled_count..'/'..total,22,y+9,14,C.TEXT,104)
            button('rules:bulk:'..v[1]..':on',say('全部启用','ENABLE ALL'),130,y,128,false)
            button('rules:bulk:'..v[1]..':off',say('全部关闭','DISABLE ALL'),266,y,112,false)
        end
        local x=22
        for _,v in ipairs({{'all','全部','ALL'},{'red','红','RED'},{'blue','蓝','BLUE'},{'green','绿','GREEN'},{'other','任务等','OTHER'}}) do
            button('rules:filter:'..v[1],say(v[2],v[3]),x,366,80,(p.rule_filter or 'all')==v[1]);x=x+86
        end
        canvas.rect(22,408,424,32,C.FIELD,951);canvas.border(22,408,424,32,C.LINE2,952)
        local search=p.edit_field=='rules:search' and p.edit_text or p.rule_search or ''
        text(search~='' and search or say('搜索名称或 ID（点击输入）','SEARCH NAME / ID'),30,416,14,C.MUTED,408)
        canvas.region('rules:search',22,408,424,32)
        local query=(p.rule_search or ''):lower()
        for _,row in ipairs(catalog.list_rules and catalog.list_rules() or catalog.list()) do
            if ((p.rule_filter or 'all')=='all' or row.group==p.rule_filter)
                and (query=='' or (row.display_name or row.name or row.debug_name):lower():find(query,1,true)
                    or tostring(row.id):find(query,1,true)
                    or (row.debug_name or row.name or ''):lower():find(query,1,true)) then rows[#rows+1]=row end
        end
        text(catalog.state.status,22,349,12,C.MUTED,424)
    end
    local selected
    for _,row in ipairs(rows) do if tostring(row.id)==tostring(p.rule_selected) then selected=row end end
    selected=selected or rows[1];p.rule_selected=selected and selected.id or nil
    local page_size=enemy and 5 or 10
    local pages=math.max(1,math.ceil(#rows/page_size))
    p.rule_page=math.max(1,math.min(pages,p.rule_page or 1))
    local top=enemy and 356 or 456
    for i=(p.rule_page-1)*page_size+1,math.min(#rows,p.rule_page*page_size) do
        local row=rows[i];local y=top+(i-(p.rule_page-1)*page_size-1)*40
        local rule=a.rule(enemy and 'enemy' or 'stratagem',row.id,role)
        local enabled=enemy and opts['ping_'..row.id] or not enemy and rule.enabled~=false
        local key='rules:select:'..row.id
        canvas.rect(22,y,424,36,row==selected and C.ROW_HI or C.PANEL,951)
        canvas.border(22,y,424,36,row==selected and C.YELLOW or C.LINE,952)
        if not enemy and canvas.icon then canvas.icon(row.icon,27,y+4,28) end
        text(row.display_name or row.name or row.debug_name,enemy and 32 or 62,y+9,14,C.TEXT,enemy and 328 or 298)
        text(enabled and 'ON' or 'OFF',392,y+10,12,enabled and C.YELLOW or C.DIM,48)
        canvas.region(key,22,y,424,36)
    end
    if not enemy then
        button('rules:prev','<',22,872,60,false);text(p.rule_page..' / '..pages..'  ('..#rows..')',98,881,14,C.MUTED,260)
        button('rules:next','>',386,872,60,false)
        text(say('新目录条目自动加入；未知分类列在“任务等”。','NEW ROWS AUTO-APPEAR; UNKNOWN GROUPS IN OTHER.'),22,919,12,C.MUTED,424)
    end
    canvas.rect(470,245,508,701,C.PANEL,950);canvas.border(470,245,508,701,C.LINE,951)
    if not selected then
        text(say('等待游戏战备目录，或没有符合筛选的条目。','WAITING FOR CATALOG / NO MATCHES.'),486,270,14,C.MUTED,470)
        text(say('进入游戏后读取；不支持的版本会停止读取。','READS IN GAME; UNSUPPORTED BUILDS STOP.'),486,305,12,C.MUTED,470)
        return
    end
    local kind=enemy and 'enemy' or 'stratagem';local rule=a.rule(kind,selected.id,role)
    text(selected.display_name or selected.name or selected.debug_name,486,262,20,C.TEXT,474)
    if not enemy then
        text(say('规则ID ','RULE ID ')..selected.id..'  · '..selected.group..'  · '..say('游戏冷却 ','GAME CD ')..string.format('%.0f',selected.cooldown)..'s',486,296,12,C.MUTED,474)
        if selected.variant_ids and #selected.variant_ids>1 then
            text(say('同名 '..#selected.variant_ids..' 个变体共用此规则','SHARED BY '..#selected.variant_ids..' SAME-NAME VARIANTS'),735,343,12,C.MUTED,225)
        end
    end
    local enabled=enemy and opts['ping_'..selected.id] or not enemy and rule.enabled~=false
    button('rules:enabled',say('此类提醒 ','THIS ALERT ')..(enabled and 'ON' or 'OFF'),486,334,230,enabled)
    local function field(name,title,y)
        local key='rule:'..kind..':'..selected.id..':'..name
        text(title,486,y,13,C.YELLOW,474)
        local value=p.edit_field==key and p.editing and p.edit_text or rule[name]
        value=value==nil and '' or tostring(value)
        local focus=p.edit_field==key and p.editing
        canvas.rect(486,y+23,474,36,C.FIELD,951);canvas.border(486,y+23,474,36,focus and C.YELLOW or C.LINE2,952)
        text(value~='' and value..(focus and '_' or '') or say('留空继承默认','BLANK = INHERIT'),494,y+33,14,focus and C.TEXT or C.MUTED,458)
        canvas.region(key,486,y+23,474,36)
    end
    field('mark_message',enemy and say('标记消息','MARK MESSAGE') or say('标记落地物品时的消息','LANDED EQUIPMENT MARK MESSAGE'),392)
    local y=478
    if not enemy then field('call_message',say('召唤 / 执行时的消息','CALL / TASK ACTION MESSAGE'),y);y=y+86 end
    field('cooldown',say('独立冷却（秒）：空 = 全局；0 = 每次新事件','RULE COOLDOWN: BLANK = GLOBAL; 0 = EVERY EVENT'),y)
    text(say('独立冷却按触发者 + 此规则分别计时。','SEPARATE TIMER PER TRIGGER PLAYER + RULE.'),486,y+78,12,C.YELLOW,474)
    text(say('0 绕过全局间隔；仍遵守总开关和事件去重。','0 BYPASSES GLOBAL INTERVAL; MASTER / DEDUPE APPLY.'),486,y+103,12,C.MUTED,474)
    text(say('变量：{玩家名} / {缩写} / {编号}','TOKENS: PLAYER NAME / SHORT / SLOT'),486,755,14,C.TEXT,474)
    text('{目标} / {类别} / {动作} / {位置}',486,786,14,C.TEXT,474)
    text(say('Enter 保存 · Esc 取消 · Ctrl+V 粘贴','ENTER SAVE · ESC CANCEL · CTRL+V PASTE'),486,828,12,C.MUTED,474)
    button('rules:inherit',say('恢复消息与冷却为默认','RESTORE MESSAGE / COOLDOWN DEFAULTS'),486,870,474,false)
    if p.hint then text(p.hint,486,919,12,C.YELLOW,474) end
end
