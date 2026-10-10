-- Dedicated configuration views using the existing Armory frame/input owner.
-- No native reads here; catalog rows and safely bound icons come from the host.
local function draw_alert_panel(canvas,p,a,catalog,chinese,version,status_text)
    local body_top=math.max(158,(canvas.body_y or 136)+10)
    local body_shift=body_top-158
    local raw_canvas=canvas
    canvas=setmetatable({}, {__index=function(_,key)
        local fn=raw_canvas[key]
        if type(fn)~='function' then return fn end
        if key=='text' or key=='wrap_text' then
            return function(value,x,y,... ) return fn(value,x,y+(y>=158 and body_shift or 0),...) end
        elseif key=='rect' or key=='border' then
            return function(x,y,w,h,... )
                local shift=y>=158 and body_shift or 0
                if x==470 and y==245 then h=math.max(1,h-body_shift) end
                return fn(x,y+shift,w,h,...)
            end
        elseif key=='region' then
            return function(key,x,y,... ) return fn(key,x,y+(y>=158 and body_shift or 0),...) end
        elseif key=='icon' then
            return function(hash,x,y,... ) return fn(hash,x,y+(y>=158 and body_shift or 0),...) end
        elseif key=='begin_viewport' then
            return function(id,x,y,w,h,content_h,row_h)
                local top=y+(y>=158 and body_shift or 0)
                return fn(id,x,top,w,math.max(1,math.min(h,946-top)),content_h,row_h)
            end
        end
        return fn
    end})
    local C=canvas.palette
    local function say(cn,en) return chinese and cn or en end
    local function text(v,x,y,size,c,w) canvas.text(v,x,y,size or 14,c or C.TEXT,w) end
    local function wrapped(v,x,y,size,c,w)
        if canvas.wrap_text then return canvas.wrap_text(v,x,y,size or 14,c or C.TEXT,w) end
        text(v,x,y,size,c,w);return size or 14
    end
    local function wrap_height(v,size,w)
        if canvas.wrap_height then return canvas.wrap_height(v,size,w) end
        return size or 14
    end
    local function input_value(v,size,w,editing)
        v=tostring(v or '')
        if editing and canvas.input_tail then return canvas.input_tail(v,size,w) end
        return v
    end
    local function begin_viewport(id,x,y,w,h,content_h)
        if canvas.begin_viewport then return canvas.begin_viewport(id,x,y,w,h,content_h,28) end
    end
    local function end_viewport()
        if canvas.end_viewport then canvas.end_viewport() end
    end
    local DETAIL_X,DETAIL_W=486,460 -- UX.begin_viewport reserves 14 units for its scrollbar.
    local function row_name(row)
        if chinese then return row.display_name or row.name or row.debug_name or tostring(row.id) end
        return row.display_name_en or row.name_en or row.debug_name or row.name or row.display_name or tostring(row.id)
    end
    local function button(key,value,x,y,w,on,disabled,min_h)
        local label_h=wrap_height(value,13,w-18)
        local h=math.max(32,label_h+16,min_h or 0)
        canvas.rect(x,y,w,h,disabled and C.FIELD or on and C.YELLOW or p.hover==key and C.ROW_HI or C.PANEL,951)
        canvas.border(x,y,w,h,disabled and C.LINE2 or on and C.YELLOW or C.LINE2,952)
        wrapped(value,x+9,y+8,13,disabled and C.DIM or on and C.INK or C.TEXT,w-18)
        if not disabled then canvas.region(key,x,y,w,h) end
        return h
    end
    local role=p.profile or 'host';local opts=a.profile(role)
    local host_h=button('profile:host',say('主机','HOST'),614,48,146,role=='host')
    local client_h=button('profile:client',say('客机','CLIENT'),768,48,146,role=='client')
    wrapped(say('输出：','OUTPUT: ')..(opts.output=='local' and say('仅自己可见','ONLY ME') or say('小队公屏','SQUAD CHAT')),
        614,48+math.max(host_h,client_h)+8,12,C.YELLOW,300)
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
        local help_y=249
        for _,line in ipairs({
            {say('飞行分类优先，不受原体型开关影响。','FLYING TAKES PRIORITY OVER SIZE.'),13,C.YELLOW},
            {say('体型采用游戏内部 Small / Medium / Large / Massive。','SIZES FOLLOW THE GAME UNIT SIZE ENUM.'),12,C.MUTED},
            {say('各类别单独设置；普通物资使用标记提醒。','CONFIGURE EACH CATEGORY; SUPPLIES USE PING SETTINGS.'),12,C.MUTED},
        }) do help_y=help_y+wrapped(line[1],22,help_y,line[2],line[3],440)+3 end
        rows.list_top=math.max(356,help_y+8)
    else
        local groups={{'red','红战备','RED'}, {'blue','蓝战备','BLUE'}, {'green','绿战备','GREEN'},
            {'mission','任务战备','MISSION STRATAGEMS'}}
        local group_y=237
        for _,v in ipairs(groups) do
            local total,enabled_count=0,0
            for _,row in ipairs(catalog.list_rules and catalog.list_rules() or catalog.list()) do
                if (v[1]=='mission' and row.family=='mission') or (v[1]~='mission' and row.group==v[1]) then
                    total=total+1
                    if a.rule('stratagem',row.id,role).enabled~=false then enabled_count=enabled_count+1 end
                end
            end
            local group_text=say(v[2],v[3])..' '..enabled_count..'/'..total
            local label_height=wrap_height(group_text,13,104)
            wrapped(group_text,22,group_y+2,13,C.TEXT,104)
            local y=group_y
            local on_h=button('rules:bulk:'..v[1]..':on',say('全部启用','ENABLE ALL'),130,y,128,false)
            local off_h=button('rules:bulk:'..v[1]..':off',say('全部关闭','DISABLE ALL'),266,y,112,false)
            group_y=group_y+math.max(38,label_height+4,on_h,off_h)
        end
        local filters_y=math.max(390,group_y+2)
        local filters_h=32
        local x=22
        for _,v in ipairs({{'all','全部','ALL'},{'red','红','RED'},{'blue','蓝','BLUE'},
            {'green','绿','GREEN'},{'mission','任务','MISSION'}}) do
            filters_h=math.max(filters_h,button('rules:filter:'..v[1],say(v[2],v[3]),x,filters_y,80,(p.rule_filter or 'all')==v[1]));x=x+86
        end
        local search_y=filters_y+filters_h+10
        canvas.rect(22,search_y,424,32,C.FIELD,951);canvas.border(22,search_y,424,32,C.LINE2,952)
        local search=p.edit_field=='rules:search' and p.edit_text or p.rule_search or ''
        local search_edit=p.edit_field=='rules:search' and p.editing
        search=input_value(search..(search_edit and '_' or ''),14,408,search_edit)
        text(search~='' and search or say('搜索名称或 ID（点击输入）','SEARCH NAME / ID'),30,search_y+8,14,C.MUTED,408)
        canvas.region('rules:search',22,search_y,424,32)
        local query=(p.rule_search or ''):lower()
        for _,row in ipairs(catalog.list_rules and catalog.list_rules() or catalog.list()) do
            local filter=p.rule_filter or 'all'
            local matches_filter=filter=='all' or (filter=='mission' and row.family=='mission')
                or (filter=='other' and row.group=='other' and row.family~='mission')
                or (filter~='mission' and filter~='other' and row.group==filter)
            if matches_filter
                and (query=='' or row_name(row):lower():find(query,1,true)
                    or tostring(row.id):find(query,1,true)
                    or (row.debug_name or row.name or ''):lower():find(query,1,true)) then rows[#rows+1]=row end
        end
        local status=status_text and status_text(catalog.state.status) or catalog.state.status
        local status_y=search_y+40
        local status_h=wrapped(status,22,status_y,12,C.MUTED,424)
        rows.list_top=status_y+status_h+8
    end
    local selected
    for _,row in ipairs(rows) do if tostring(row.id)==tostring(p.rule_selected) then selected=row end end
    selected=selected or rows[1];p.rule_selected=selected and selected.id or nil
    local batch_fields={{'mark_message',say('标记消息','MARK MESSAGE')},
        {'call_message',say('召唤 / 执行消息','CALL / TASK MESSAGE')},
        {'cooldown',say('独立冷却（秒）：空 = 默认；0 合法','RULE COOLDOWN: BLANK = DEFAULT; 0 IS VALID')}}
    local function batch_toggle(y)
        local key=p.rule_batch_edit and 'rules:batch:close' or 'rules:batch:open'
        return button(key,p.rule_batch_edit and say('返回单项编辑','BACK TO SINGLE RULE')
            or say('批量编辑筛选 ('..#rows..')','BULK EDIT ('..#rows..')'),DETAIL_X,y or 334,DETAIL_W,false)
    end
    local function draw_batch_fields(start_y,shared_view)
        start_y=start_y or 378
        local intro=say('对当前筛选的全部匹配项应用；包含其他分页。','APPLIES TO ALL FILTER MATCHES, INCLUDING OTHER PAGES.')
        local pad=shared_view and 0 or (canvas.wrap_start_pad and canvas.wrap_start_pad(13) or 0)
        local row_heights,content_h={},pad+wrap_height(intro,13,DETAIL_W)+8
        for i,item in ipairs(batch_fields) do
            local action_h=math.max(wrap_height(say('应用到筛选 ('..#rows..')','APPLY ('..#rows..')'),13,238-18)+16,
                wrap_height(say('恢复默认 ('..#rows..')','RESET ('..#rows..')'),13,DETAIL_W-252-18)+16,32)
            row_heights[i]=wrap_height(item[2],12,DETAIL_W)+3+34+8+action_h+8
            content_h=content_h+row_heights[i]
        end
        local hint=p.hint and (status_text and status_text(p.hint) or p.hint) or nil
        if hint then content_h=content_h+wrap_height(hint,12,DETAIL_W)+4 end
        local view_h=math.max(1,940-(start_y-pad+body_shift))
        local view=shared_view or begin_viewport('rules_detail',DETAIL_X,start_y-pad,474,view_h,content_h)
        local draw_w=view and view.w or DETAIL_W
        wrapped(intro,DETAIL_X,start_y+pad,13,C.YELLOW,draw_w)
        p.rule_batch_drafts=p.rule_batch_drafts or {}
        p.rule_batch_drafts[role]=p.rule_batch_drafts[role] or {}
        local drafts=p.rule_batch_drafts[role]
        local offset=wrap_height(intro,13,DETAIL_W)+8
        for i,item in ipairs(batch_fields) do
            local field,title=item[1],item[2];local y=start_y+offset
            local key='rules:batch:edit:'..field
            local editing=p.edit_field==key and p.editing
            local value=editing and (p.edit_text or '') or drafts[field] or ''
            local title_h=wrapped(title,DETAIL_X,y,12,C.YELLOW,draw_w)
            local field_y=y+title_h+3
            canvas.rect(DETAIL_X,field_y,draw_w,34,editing and C.ROW_HI or C.FIELD,951)
            canvas.border(DETAIL_X,field_y,draw_w,34,editing and C.YELLOW or C.LINE2,952)
            local shown=value~='' and input_value(value..(editing and '_' or ''),13,draw_w-16,editing)
                or say('点击输入本字段批量值','CLICK TO ENTER A VALUE FOR THIS FIELD')
            text(shown,DETAIL_X+8,field_y+8,13,editing and C.TEXT or C.MUTED,draw_w-16)
            canvas.region(key,DETAIL_X,field_y,draw_w,34)
            local count=#rows
            local action_y=field_y+42
            local apply_label=say('应用 ('..count..')','APPLY ('..count..')')
            local reset_label=say('恢复默认 ('..count..')','RESET ('..count..')')
            local action_h=math.max(32,wrap_height(apply_label,13,220)+16,
                wrap_height(reset_label,13,draw_w-270)+16)
            button('rules:batch:apply:'..field,apply_label,DETAIL_X,action_y,238,false,count==0,action_h)
            button('rules:batch:reset:'..field,reset_label,DETAIL_X+246,action_y,draw_w-252,false,count==0,action_h)
            offset=offset+row_heights[i]
        end
        if hint then wrapped(hint,DETAIL_X,start_y+offset,12,C.YELLOW,draw_w) end
        if not shared_view then end_viewport() end
        return start_y+offset
    end
    local top=rows.list_top or (enemy and 356 or 480)
    local footer_top=enemy and 930 or 860
    local available_rows=math.max(1,math.floor((footer_top-body_shift-top)/40))
    local page_size=enemy and math.min(5,available_rows) or available_rows
    local pages=math.max(1,math.ceil(#rows/page_size))
    p.rule_page=math.max(1,math.min(pages,p.rule_page or 1))
    for i=(p.rule_page-1)*page_size+1,math.min(#rows,p.rule_page*page_size) do
        local row=rows[i];local y=top+(i-(p.rule_page-1)*page_size-1)*40
        local rule=a.rule(enemy and 'enemy' or 'stratagem',row.id,role)
        local enabled=enemy and opts['ping_'..row.id] or not enemy and rule.enabled~=false
        local key='rules:select:'..row.id
        canvas.rect(22,y,424,36,row==selected and C.ROW_HI or C.PANEL,951)
        canvas.border(22,y,424,36,row==selected and C.YELLOW or C.LINE,952)
        if not enemy and canvas.icon then canvas.icon(row.icon,27,y+4,28) end
        text(row_name(row),enemy and 32 or 62,y+9,14,C.TEXT,enemy and 328 or 298)
        text(enabled and 'ON' or 'OFF',392,y+10,12,enabled and C.YELLOW or C.DIM,48)
        canvas.region(key,22,y,424,36)
    end
    if not enemy or pages>1 then
        button('rules:prev','<',22,872-body_shift,60,false);text(p.rule_page..' / '..pages..'  ('..#rows..')',98,881-body_shift,14,C.MUTED,260)
        button('rules:next','>',386,872-body_shift,60,false)
        if not enemy then wrapped(say('新目录条目自动加入；未知分类列在“任务等”。','NEW ROWS AUTO-APPEAR; UNKNOWN GROUPS IN OTHER.'),22,919-body_shift,12,C.MUTED,424) end
    end
    canvas.rect(470,245,508,701,C.PANEL,950);canvas.border(470,245,508,701,C.LINE,951)
    if not selected then
        local empty_y=270
        empty_y=empty_y+wrapped(say('等待游戏战备目录，或没有符合筛选的条目。','WAITING FOR CATALOG / NO MATCHES.'),486,empty_y,14,C.MUTED,470)+8
        empty_y=empty_y+wrapped(say('进入游戏后读取；不支持的版本会停止读取。','READS IN GAME; UNSUPPORTED BUILDS STOP.'),486,empty_y,12,C.MUTED,470)+10
        if not enemy then
            local toggle_h=batch_toggle(empty_y)
            if p.rule_batch_edit then draw_batch_fields(empty_y+toggle_h+8) end
        end
        return
    end
    local kind=enemy and 'enemy' or 'stratagem';local rule=a.rule(kind,selected.id,role)
    local title=row_name(selected)
    local info=not enemy and (say('规则ID ','RULE ID ')..selected.id..'  · '..selected.group..'  · '..say('游戏冷却 ','GAME CD ')..string.format('%.0f',selected.cooldown)..'s') or nil
    local variants=not enemy and selected.variant_ids and #selected.variant_ids>1
        and say('同名 '..#selected.variant_ids..' 个变体共用此规则','SHARED BY '..#selected.variant_ids..' SAME-NAME VARIANTS') or nil
    local enabled=enemy and opts['ping_'..selected.id] or not enemy and rule.enabled~=false
    local enabled_label=say('此类提醒 ','THIS ALERT ')..(enabled and 'ON' or 'OFF')
    local toggle_label=p.rule_batch_edit and say('返回单项编辑','BACK TO SINGLE RULE')
        or say('批量编辑筛选 ('..#rows..')','BULK EDIT ('..#rows..')')
    local fields={{'mark_message',enemy and say('标记消息','MARK MESSAGE') or say('标记落地物品时的消息','LANDED EQUIPMENT MARK MESSAGE')}}
    if not enemy then fields[#fields+1]={'call_message',say('召唤 / 执行时的消息','CALL / TASK ACTION MESSAGE')} end
    fields[#fields+1]={'cooldown',say('独立冷却（秒）：空 = 全局；0 = 每次新事件','RULE COOLDOWN: BLANK = GLOBAL; 0 = EVERY EVENT')}
    local help={
        {say('独立冷却按触发者 + 此规则分别计时。','SEPARATE TIMER PER TRIGGER PLAYER + RULE.'),12,C.YELLOW},
        {say('0 绕过全局间隔；仍遵守总开关和事件去重。','0 BYPASSES GLOBAL INTERVAL; MASTER / DEDUPE APPLY.'),12,C.MUTED},
        {'{玩家名}/{player_name}',12,C.TEXT},{'{缩写}/{abbr}  ·  {编号}/{slot}',12,C.TEXT},
        {'{目标}/{target}',12,C.TEXT},{'{战备}/{stratagem}',12,C.TEXT},
        {'{类别}/{category}',12,C.TEXT},{'{动作}/{action}',12,C.TEXT},
        {'{任务名}/{objective}',12,C.TEXT},{'{任务类型}/{objective_type}',12,C.TEXT},
        {'{位置}/{position}',12,C.TEXT},
        {say('Enter 保存 · Esc 取消 · Ctrl+V 粘贴','ENTER SAVE · ESC CANCEL · CTRL+V PASTE'),12,C.MUTED},
    }
    if p.hint then help[#help+1]={status_text and status_text(p.hint) or p.hint,12,C.YELLOW} end
    local pad=canvas.wrap_start_pad and canvas.wrap_start_pad(20) or 0
    local content_h=pad+wrap_height(title,20,DETAIL_W)+8
    if info then content_h=content_h+wrap_height(info,12,DETAIL_W)+6 end
    if variants then content_h=content_h+wrap_height(variants,12,DETAIL_W)+6 end
    local enabled_h=math.max(32,wrap_height(enabled_label,13,212)+16)
    content_h=content_h+enabled_h+8
    if not enemy then content_h=content_h+math.max(32,wrap_height(toggle_label,13,218)+16)+8 end
    if p.rule_batch_edit and not enemy then
        local intro=say('对当前筛选的全部匹配项应用；包含其他分页。','APPLIES TO ALL FILTER MATCHES, INCLUDING OTHER PAGES.')
        content_h=content_h+(canvas.wrap_start_pad and canvas.wrap_start_pad(13) or 0)+wrap_height(intro,13,DETAIL_W)+8
        for _,item in ipairs(batch_fields) do
            local count=#rows
            local action_h=math.max(32,wrap_height(say('应用 ('..count..')','APPLY ('..count..')'),13,220)+16,
                wrap_height(say('恢复默认 ('..count..')','RESET ('..count..')'),13,DETAIL_W-270)+16)
            content_h=content_h+wrap_height(item[2],12,DETAIL_W)+3+34+8+action_h+8
        end
        local hint=p.hint and (status_text and status_text(p.hint) or p.hint) or nil
        if hint then content_h=content_h+wrap_height(hint,12,DETAIL_W)+4 end
    else
        for _,item in ipairs(fields) do content_h=content_h+wrap_height(item[2],13,DETAIL_W)+4+36+6 end
        content_h=content_h+2
        for _,item in ipairs(help) do content_h=content_h+wrap_height(item[1],item[2],DETAIL_W)+3 end
    end
    local content_top=262
    local content_bottom=876
    local view=begin_viewport('rules_detail',DETAIL_X,content_top-pad,474,
        math.max(1,content_bottom-(content_top-pad+body_shift)),content_h)
    local draw_w=view and view.w or DETAIL_W
    local y=content_top+pad
    y=y+wrapped(title,DETAIL_X,y,20,C.TEXT,draw_w)+8
    if info then y=y+wrapped(info,DETAIL_X,y,12,C.MUTED,draw_w)+6 end
    if variants then y=y+wrapped(variants,DETAIL_X,y,12,C.MUTED,draw_w)+6 end
    local enabled_h=button('rules:enabled',enabled_label,DETAIL_X,y,230,enabled)
    y=y+enabled_h+8
    if not enemy then
        local toggle_h=batch_toggle(y)
        y=y+toggle_h+8
        if p.rule_batch_edit then
            draw_batch_fields(y,view)
            end_viewport()
            button('rules:inherit',say('恢复消息与冷却为默认','RESTORE MESSAGE / COOLDOWN DEFAULTS'),486,902-body_shift,474,false)
            return
        end
    end
    local function field(name,title,y)
        local key='rule:'..kind..':'..selected.id..':'..name
        local title_h=wrapped(title,DETAIL_X,y,13,C.YELLOW,draw_w)
        local value=p.edit_field==key and p.editing and p.edit_text or rule[name]
        value=value==nil and '' or tostring(value)
        local focus=p.edit_field==key and p.editing
        local field_y=y+title_h+4
        canvas.rect(DETAIL_X,field_y,draw_w,36,C.FIELD,951)
        canvas.border(DETAIL_X,field_y,draw_w,36,focus and C.YELLOW or C.LINE2,952)
        local shown=value~='' and input_value(value..(focus and '_' or ''),14,draw_w-16,focus)
            or say('留空继承默认','BLANK = INHERIT')
        text(shown,DETAIL_X+8,field_y+10,14,focus and C.TEXT or C.MUTED,draw_w-16)
        canvas.region(key,DETAIL_X,field_y,draw_w,36)
        return field_y+42
    end
    for _,item in ipairs(fields) do y=field(item[1],item[2],y) end
    y=y+2
    for _,item in ipairs(help) do y=y+wrapped(item[1],DETAIL_X,y,item[2],item[3],draw_w)+3 end
    end_viewport()
    button('rules:inherit',say('恢复消息与冷却为默认','RESTORE MESSAGE / COOLDOWN DEFAULTS'),486,902-body_shift,474,false)
end
