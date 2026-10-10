-- Named automation preset page. The frame and hit testing belong to auto_chat.lua;
-- this renderer only records ordinary panel regions through UX.
local function draw_preset_panel(UX, PANEL, automation, preset_library, font_ok, status_text)
    local C, W, H = UX.palette, 1000, 990
    local text, rect, border, region = UX.text, UX.rect, UX.border, UX.region
    local wrap, wrap_height = UX.wrap_text, UX.wrap_height
    local begin_viewport, end_viewport = UX.begin_viewport, UX.end_viewport
    local input_tail = UX.input_tail
    local role = PANEL.profile or 'host'
    local options = automation.profile(role)
    local function say(cn, en) return font_ok and cn or en end
    local TOP = math.max(158, (UX.body_y or 136) + 10)
    local function text_block(value, x, y, size, colour, limit, align)
        if wrap then return wrap(value, x, y, size, colour, limit, align) end
        text(value, x, y, size, colour, limit, align)
        return size + 4
    end
    local function block_height(value, size, limit)
        return wrap_height and wrap_height(value, size, limit) or size + 4
    end
    local function button(key, title, x, y, w, min_h, active, disabled)
        local label_h = block_height(title, 13, w - 12)
        local h = math.max(min_h or 28, label_h + 8)
        local hovered = PANEL.hover == key
        rect(x, y, w, h, disabled and C.FIELD or active and C.YELLOW or hovered and C.ROW_HI or C.PANEL, 951)
        border(x, y, w, h, disabled and C.LINE2 or active and C.YELLOW or hovered and C.TEXT or C.LINE2, 952)
        local colour = disabled and C.DIM or active and C.INK or C.TEXT
        text_block(title, x + w/2, y + math.max(4, (h-label_h)/2), 13, colour, w-12, 'center')
        if not disabled then region(key,x,y,w,h) end
        return h
    end
    local function field_height(title, width)
        return block_height(title, 11, width) + 4 + 31
    end
    local function field(key, title, value, x, y, width)
        local title_h = text_block(title, x, y, 11, C.YELLOW, width)
        local field_y = y + title_h + 4
        local focus = PANEL.editing and PANEL.edit_field == key
        local shown = tostring(focus and (PANEL.edit_text or value) or value or '')
        local visible = focus and input_tail and input_tail(shown .. '_', 13, width - 16)
            or focus and shown .. '_' or shown
        rect(x,field_y,width,31,focus and C.ROW_HI or C.FIELD,951)
        border(x,field_y,width,31,focus and C.YELLOW or C.LINE2,952)
        text(visible,x+8,field_y+8,13,focus and C.TEXT or C.MUTED,width-16)
        region(key,x,field_y,width,31)
        return field_y + 31
    end

    local list_x, list_w = 22, 342
    local detail_x, detail_w = 390, 568
    local detail_content_w = detail_w - 14
    local bottom = H - 52
    rect(list_x,TOP,list_w,bottom-TOP,C.PANEL,950);border(list_x,TOP,list_w,bottom-TOP,C.LINE,951)
    rect(378,TOP,W-400,bottom-TOP,C.PANEL,950);border(378,TOP,W-400,bottom-TOP,C.LINE,951)
    local list_title = say('命名自动消息预设','NAMED AUTOMATION PRESETS')
    local list_title_h = text_block(list_title,40,TOP+20,20,C.TEXT,306)

    PANEL.preset_selected_by_role=PANEL.preset_selected_by_role or {}
    PANEL.preset_page_by_role=PANEL.preset_page_by_role or {}
    PANEL.preset_index_cache_by_role=PANEL.preset_index_cache_by_role or {}
    local selected_id=PANEL.preset_selected_by_role[role]
    local entries=(preset_library._list_view or preset_library.list)(role)
    local revision=preset_library.state and preset_library.state.revision or 0
    local index_cache=PANEL.preset_index_cache_by_role[role]
    if not index_cache or index_cache.revision~=revision or index_cache.entries~=entries then
        local by_id={}
        for _,entry in ipairs(entries) do by_id[entry.id]=entry end
        index_cache={revision=revision,entries=entries,by_id=by_id}
        PANEL.preset_index_cache_by_role[role]=index_cache
    end
    if selected_id and not index_cache.by_id[selected_id] then
        selected_id=nil;PANEL.preset_selected_by_role[role]=nil
    end
    if not selected_id then
        local english_id='builtin-'..role..'-en'
        local english=index_cache.by_id[english_id]
        if english and english.builtin==true then selected_id=english_id;PANEL.preset_selected_by_role[role]=english_id end
    end
    local selected=selected_id and index_cache.by_id[selected_id] or nil
    local count_text=say('共 '..#entries..' 个预设',#entries..' PRESETS')
    local count_h=text_block(count_text,40,TOP+20+list_title_h+4,12,C.MUTED,306)
    if preset_library.state.error then
        local error_top=TOP+60
        text_block(say('预设库读取失败，已锁定写入：','LIBRARY ERROR; WRITES DISABLED:'),40,error_top,12,C.BAD,300)
        text_block(preset_library.state.error,40,error_top+26,11,C.BAD,300)
    elseif #entries==0 then text_block(say('暂无已保存预设','NO SAVED PRESETS'),40,TOP+66,14,C.DIM,300) end
    PANEL.preset_page_size_by_role=PANEL.preset_page_size_by_role or {}
    local list_top=math.max(TOP+98,TOP+20+list_title_h+count_h+16)
    local page_size=math.max(1,math.min(16,math.floor((H-160-list_top)/36)))
    PANEL.preset_page_size_by_role[role]=page_size
    local pages=math.max(1,math.ceil(#entries/page_size))
    local page=PANEL.preset_page_by_role[role] or 1
    page=math.max(1,math.min(pages,page));PANEL.preset_page_by_role[role]=page
    local first=(page-1)*page_size+1
    for i=first,math.min(#entries,first+page_size-1) do
        local entry=entries[i];local y=list_top+(i-first)*36
        local chosen=entry.id==selected_id
        rect(38,y,308,30,chosen and C.ROW_HI or C.ROW,951)
        border(38,y,308,30,chosen and C.YELLOW or C.LINE2,952)
        text(entry.name,48,y+8,13,chosen and C.YELLOW or C.TEXT,244)
        region('preset:select:'..entry.id,38,y,308,30)
    end
    button('preset:prev','<',38,H-132,40,26,page>1)
    text(page..' / '..pages,94,H-126,12,C.MUTED)
    button('preset:next','>',142,H-132,40,26,page<pages)
    button('preset:save',say('保存当前配置','SAVE CURRENT'),38,H-94,146,32,false)
    button('preset:replace',say('替换所选','REPLACE'),194,H-94,152,32,false,selected and selected.builtin==true)

    local header_y=TOP+20
    local edit_label=say('编辑目标：','EDITING:')..say(role=='host' and '主机' or '客机',role:upper())
    local active_label=say('当前：','ACTIVE: ')..(automation.state.active_role=='host' and say('主机','HOST')
        or automation.state.active_role=='client' and say('客机','CLIENT') or say('等待','WAITING'))
    local edit_label_h=text_block(edit_label,detail_x,header_y,13,C.YELLOW,270)
    local active_label_h=text_block(active_label,682,header_y,12,C.MUTED,130)
    local back_h=button('preset:back',say('返回设置','BACK TO SETTINGS'),822,TOP+10,136,30,false)
    local viewport_top=math.max(TOP+44,header_y+edit_label_h+8,header_y+active_label_h+8,TOP+10+back_h+8)
    local output_line=say('当前配置输出：','CURRENT OUTPUT: ')..
        (options.output=='local' and say('仅自己可见','ONLY ME') or say('小队公屏','SQUAD CHAT'))

    local selected_line=selected and (say('已选：','SELECTED: ')..selected.name) or say('请选择预设','SELECT A PRESET')
    local selected_width=detail_content_w-150
    local selected_h=block_height(selected_line,13,selected_width)
    local rename_h=math.max(30,selected_h+8)
    local cached=index_cache.validation
    if selected and (not cached or cached.id~=selected.id or cached.payload~=selected.payload) then
        local ok,profile=automation.validate_profile(selected.payload)
        cached={id=selected.id,payload=selected.payload,valid=ok,parsed=profile}
        index_cache.validation=cached
    end
    local saved=selected and cached and cached.valid and cached.parsed and cached.parsed.values
    local preview_lines={}
    if saved then
        preview_lines[1]=say('将载入：','WILL LOAD: ')..(saved.output=='local' and say('仅自己可见','ONLY ME') or say('小队公屏','SQUAD CHAT'))
        preview_lines[2]=say('自动消息：','AUTO SEND: ')..(saved.enabled and 'ON' or 'OFF')..'    '..say('标记：','PING: ')..(saved.ping and 'ON' or 'OFF')
    else preview_lines[1]=say('无法预览所选预设内容','SELECTED PRESET CANNOT BE PREVIEWED') end
    local count_line
    if selected then
        local count=0;for _ in selected.payload:gmatch('\nrule_[^=]+=[^\n]*') do count=count+1 end
        count_line=say('包含自动消息设置、模板和细粒度规则；规则字段：','AUTOMATION OPTIONS, TEMPLATES AND FINE GRAIN RULES; RULE FIELDS: ')..tostring(count)
    end
    local hint_line=PANEL.hint and status_text and status_text(PANEL.hint) or PANEL.hint
        or say('选择主机或客机配置后，点击应用按钮写入该角色。','Select a host or client configuration, then apply the preset to that role.')
    local export_line=PANEL.preset_export_path and (say('导出位置：','EXPORTED: ')..PANEL.preset_export_path) or nil
    local detail_h=8+block_height(output_line,12,detail_content_w)+10+field_height(say('预设名称','PRESET NAME'),detail_content_w)
        +10+math.max(selected_h,rename_h)+10
    for _,line in ipairs(preview_lines) do detail_h=detail_h+block_height(line,12,detail_content_w)+4 end
    if count_line then detail_h=detail_h+block_height(count_line,12,detail_content_w)+8 end
    local apply_title=say(role=='host' and '应用到主机配置' or '应用到客机配置',
        role=='host' and 'APPLY TO HOST CONFIG' or 'APPLY TO CLIENT CONFIG')
    local action_h=math.max(34,block_height(apply_title,13,186)+8,block_height(say('导出文件','EXPORT FILE'),13,136)+8,
        block_height(say('删除','DELETE'),13,162)+8)
    detail_h=detail_h+action_h+10+field_height(say('导入文件路径','IMPORT FILE PATH'),detail_content_w)+10
        +math.max(34,block_height(say('导入路径中的文件','IMPORT FILE FROM PATH'),13,detail_content_w-18)+8)
        +10+block_height(hint_line,12,detail_content_w)+6
    if export_line then detail_h=detail_h+block_height(export_line,11,detail_content_w)+4 end
    local content_pad=math.max(2,math.ceil(((UX.wrap_height and UX.wrap_height('M',13,detail_content_w) or 15)-13)*0.5+2))
    local viewport=begin_viewport and begin_viewport('preset_detail',detail_x,viewport_top,detail_w,
        math.max(1,bottom-(viewport_top+10)),detail_h+content_pad,32) or nil
    local detail_w_active=viewport and viewport.w or detail_w
    local dy=viewport_top+content_pad
    dy=dy+text_block(output_line,detail_x,dy,12,C.MUTED,detail_w_active)+10
    dy=field('preset:name',say('预设名称','PRESET NAME'),PANEL.preset_name or '',detail_x,dy,detail_w_active)+10
    local actual_selected_h=text_block(selected_line,detail_x,dy+math.max(0,(rename_h-selected_h)/2),13,
        selected and C.TEXT or C.DIM,selected_width)
    button('preset:rename',say('改名','RENAME'),detail_x+detail_w_active-136,dy,136,rename_h,false,selected and selected.builtin==true)
    dy=dy+math.max(actual_selected_h,rename_h)+10
    for _,line in ipairs(preview_lines) do dy=dy+text_block(line,detail_x,dy,12,saved and C.YELLOW or C.BAD,detail_w_active)+4 end
    if count_line then dy=dy+text_block(count_line,detail_x,dy,12,C.MUTED,detail_w_active)+8 end
    button('preset:apply',apply_title,detail_x,dy,198,action_h,false)
    button('preset:export',say('导出文件','EXPORT FILE'),detail_x+210,dy,148,action_h,false)
    button('preset:delete',say('删除','DELETE'),detail_x+370,dy,162,action_h,false,selected and selected.builtin==true)
    dy=dy+action_h+10
    dy=field('preset:path',say('导入文件路径','IMPORT FILE PATH'),PANEL.preset_path or '',detail_x,dy,detail_w_active)+10
    dy=dy+button('preset:import',say('导入路径中的文件','IMPORT FILE FROM PATH'),detail_x,dy,detail_w_active,34,false)+10
    dy=dy+text_block(hint_line,detail_x,dy,12,PANEL.hint and C.YELLOW or C.MUTED,detail_w_active)+6
    if export_line then text_block(export_line,detail_x,dy,11,C.GOOD,detail_w_active) end
    if end_viewport then end_viewport() end
end
