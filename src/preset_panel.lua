-- Named automation preset page. The frame and hit testing belong to auto_chat.lua;
-- this renderer only records ordinary panel regions through UX.
local function draw_preset_panel(UX, PANEL, automation, preset_library, font_ok, status_text)
    local C, W, H = UX.palette, 1000, 990
    local text, rect, border, region = UX.text, UX.rect, UX.border, UX.region
    local role = PANEL.profile or 'host'
    local options = automation.profile(role)
    local function say(cn, en) return font_ok and cn or en end
    local function button(key, title, x, y, w, h, active, disabled)
        local hovered = PANEL.hover == key
        rect(x, y, w, h, disabled and C.FIELD or active and C.YELLOW or hovered and C.ROW_HI or C.PANEL, 951)
        border(x, y, w, h, disabled and C.LINE2 or active and C.YELLOW or hovered and C.TEXT or C.LINE2, 952)
        text(title, x+w/2, y+(h-13)/2, 13, disabled and C.DIM or active and C.INK or C.TEXT, w-12, 'center')
        if not disabled then region(key, x, y, w, h) end
    end
    local function field(key, title, value, y)
        text(title, 390, y, 11, C.YELLOW, 568)
        local focus = PANEL.editing and PANEL.edit_field == key
        rect(390,y+17,568,31,focus and C.ROW_HI or C.FIELD,951)
        border(390,y+17,568,31,focus and C.YELLOW or C.LINE2,952)
        local shown = focus and (PANEL.edit_text or value) or value
        text(tostring(shown or '')..(focus and '_' or ''),398,y+25,13,focus and C.TEXT or C.MUTED,552)
        region(key,390,y+17,568,31)
    end
    rect(22,158,342,H-210,C.PANEL,950);border(22,158,342,H-210,C.LINE,951)
    rect(378,158,W-400,H-210,C.PANEL,950);border(378,158,W-400,H-210,C.LINE,951)
    text(say('命名自动消息预设','NAMED AUTOMATION PRESETS'),40,178,20,C.TEXT,306)
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
    if selected_id then
        if not index_cache.by_id[selected_id] then selected_id=nil;PANEL.preset_selected_by_role[role]=nil end
    end
    if not selected_id then
        local english_id='builtin-'..role..'-en'
        local english=index_cache.by_id[english_id]
        if english and english.builtin==true then
            selected_id=english_id
            PANEL.preset_selected_by_role[role]=english_id
        end
    end
    local selected=selected_id and index_cache.by_id[selected_id] or nil
    text(say('共 '..#entries..' 个预设',#entries..' PRESETS'),346,184,12,C.MUTED,nil,'right')
    if preset_library.state.error then
        text(say('预设库读取失败，已锁定写入：','LIBRARY ERROR; WRITES DISABLED:'),40,218,12,C.BAD,300)
        text(preset_library.state.error,40,240,11,C.BAD,300)
    elseif #entries==0 then text(say('暂无已保存预设','NO SAVED PRESETS'),40,224,14,C.DIM,300) end
    local pages=math.max(1,math.ceil(#entries/16))
    local page=PANEL.preset_page_by_role[role] or 1
    page=math.max(1,math.min(pages,page));PANEL.preset_page_by_role[role]=page
    local first=(page-1)*16+1
    for i=first,math.min(#entries,first+15) do
        local entry=entries[i];local y=266+(i-first)*36
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

    text(say('编辑目标：','EDITING:')..say(role=='host' and '主机' or '客机',role:upper()),390,178,13,C.YELLOW,270)
    text(say('当前：','ACTIVE: ')..(automation.state.active_role=='host' and say('主机','HOST') or automation.state.active_role=='client' and say('客机','CLIENT') or say('等待','WAITING')),682,178,12,C.MUTED,130)
    button('preset:back',say('返回设置','BACK TO SETTINGS'),822,168,136,30,false)
    text(say('当前配置输出：','CURRENT OUTPUT: ')..(options.output=='local' and say('仅自己可见','ONLY ME') or say('小队公屏','SQUAD CHAT')),390,201,12,C.MUTED,568)
    field('preset:name',say('预设名称','PRESET NAME'),PANEL.preset_name or '',230)
    text(selected and (say('已选：','SELECTED: ')..selected.name) or say('请选择预设','SELECT A PRESET'),390,348,13,selected and C.TEXT or C.DIM,420)
    button('preset:rename',say('改名','RENAME'),822,340,136,30,false,selected and selected.builtin==true)
    local valid,parsed
    if selected then
        local cached=index_cache.validation
        if not cached or cached.id~=selected.id or cached.payload~=selected.payload then
            local ok,profile=automation.validate_profile(selected.payload)
            cached={id=selected.id,payload=selected.payload,valid=ok,parsed=profile}
            index_cache.validation=cached
        end
        valid,parsed=cached.valid,cached.parsed
    end
    local saved=valid and parsed and parsed.values
    if saved then
        text(say('将载入：','WILL LOAD: ')..(saved.output=='local' and say('仅自己可见','ONLY ME') or say('小队公屏','SQUAD CHAT')),390,376,12,C.YELLOW,568)
        text(say('自动消息：','AUTO SEND: ')..(saved.enabled and 'ON' or 'OFF')..'    '..say('标记：','PING: ')..(saved.ping and 'ON' or 'OFF'),390,394,12,C.MUTED,568)
    else text(say('无法预览所选预设内容','SELECTED PRESET CANNOT BE PREVIEWED'),390,376,12,C.BAD,568) end
    if selected then
        local count=0;for _ in selected.payload:gmatch('\nrule_[^=]+=[^\n]*') do count=count+1 end
        text(say('包含自动消息设置、模板和细粒度规则；规则字段：','AUTOMATION OPTIONS, TEMPLATES AND FINE GRAIN RULES; RULE FIELDS: ')..tostring(count),390,412,12,C.MUTED,568)
    end
    button('preset:apply',say(role=='host' and '应用到主机配置' or '应用到客机配置',
        role=='host' and 'APPLY TO HOST CONFIG' or 'APPLY TO CLIENT CONFIG'),390,432,210,34,false)
    button('preset:export',say('导出文件','EXPORT FILE'),612,432,160,34,false)
    button('preset:delete',say('删除','DELETE'),784,432,174,34,false,selected and selected.builtin==true)
    field('preset:path',say('导入文件路径','IMPORT FILE PATH'),PANEL.preset_path or '',488)
    button('preset:import',say('导入路径中的文件','IMPORT FILE FROM PATH'),390,556,276,34,false)
    text(PANEL.hint and status_text and status_text(PANEL.hint) or PANEL.hint
        or say('选择主机或客机配置后，点击应用按钮写入该角色。','Select a host or client configuration, then apply the preset to that role.'),390,606,12,PANEL.hint and C.YELLOW or C.MUTED,568)
    if PANEL.preset_export_path then text(say('导出位置：','EXPORTED: ')..PANEL.preset_export_path,390,638,11,C.GOOD,568) end
end
