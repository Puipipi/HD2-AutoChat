-- Pure language selection and presentation strings. No game APIs or native reads.
local function build_language(env)
    env=type(env)=='table' and env or {}
    local state={locale='en',option=nil,due=0}
    local M={}

    -- English fallback is deliberate for every language outside Chinese.
    local phrases={
        ['category.building']={zh='任务建筑',en='MISSION BUILDING'},
        ['category.stratagem']={zh='战备提示',en='STRATAGEM'},
        ['category.map']={zh='地图标记',en='MAP MARKER'},
        ['category.poi']={zh='特殊目标',en='SPECIAL TARGET'},
        ['category.mission_items']={zh='任务物品',en='MISSION ITEMS'},
        ['category.small_enemy']={zh='小型敌人',en='SMALL ENEMY'},
        ['category.flying_enemy']={zh='飞行敌人',en='FLYING ENEMY'},
        ['category.medium_enemy']={zh='中型敌人',en='MEDIUM ENEMY'},
        ['category.large_enemy']={zh='大型敌人',en='LARGE ENEMY'},
        ['category.giant_enemy']={zh='巨型敌人',en='GIANT ENEMY'},
        ['category.supplies']={zh='普通物资',en='SUPPLIES'},
        ['supply.sample']={zh='样本',en='SAMPLES'},
        ['supply.ammunition']={zh='弹药',en='AMMUNITION'},
        ['supply.stim_case']={zh='针剂盒',en='STIM CASE'},
        ['supply.grenade_case']={zh='手雷盒',en='GRENADE CASE'},
        ['supply.mission_sample_box']={zh='任务样本箱',en='MISSION SAMPLE BOX'},
        ['toggle.supplies']={zh='普通物资提醒',en='SUPPLY ALERTS'},
        ['toggle.poi']={zh='特殊目标提醒',en='SPECIAL TARGET ALERTS'},
        ['toggle.mission_items']={zh='任务物品提醒',en='MISSION ITEM ALERTS'},
        ['tab.special_targets']={zh='特殊目标',en='SPECIAL TARGETS'},
        ['tab.mission_items']={zh='任务物品',en='MISSION ITEMS'},
        ['label.enabled']={zh='启用',en='ENABLED'},
        ['label.message']={zh='消息模板',en='MESSAGE TEMPLATE'},
        ['label.cooldown']={zh='冷却（秒）',en='COOLDOWN (SECONDS)'},
        ['label.inherit_default']={zh='留空继承默认',en='BLANK = INHERIT DEFAULT'},
        ['action.mark']={zh='标记',en='marked'},
        ['action.summon']={zh='召唤',en='called in'},
        ['action.start']={zh='开始',en='started'},
        ['objective.primary']={zh='主线任务',en='PRIMARY OBJECTIVE'},
        ['objective.prerequisite']={zh='主线前置任务',en='PREREQUISITE'},
        ['objective.optional']={zh='支线任务',en='OPTIONAL OBJECTIVE'},
        ['objective.tactical']={zh='战术任务',en='TACTICAL OBJECTIVE'},
        ['objective.unknown']={zh='任务',en='OBJECTIVE'},
    }
    local stock={
        ['欢迎加入小队！']='Welcome to the squad!',
        ['标记了{目标}（{类别}）']='Marked {目标} ({类别})',
        ['{玩家名}召唤了{目标}']='{玩家名} called in {目标}',
        ['{玩家名}正在开始{目标}']='{玩家名} started {目标}',
        ['自动聊天测试消息']='HELLO FROM AUTOCHAT',
        -- Exact legacy stock text only; custom text is returned unchanged.
        ['队友标记了{类别}，请注意！']='A teammate marked {类别}.',
    }
    local stock_en={}
    for zh,en in pairs(stock) do stock_en[en]=en end

    -- Exact UI statuses and errors emitted by the catalog and preset flows.
    -- Unknown strings pass through untouched so preset names and custom text
    -- are never guessed at or translated as if they were interface copy.
    local statuses={
        ['等待战备目录']='Waiting for stratagem catalog',
        ['战备目录：不支持的游戏版本']='Stratagem catalog: unsupported game version',
        ['战备目录数据暂不可读']='Stratagem catalog data is temporarily unreadable',
        ['选择主机或客机配置后，点击应用按钮写入该角色。']='Select a host or client configuration, then apply the preset to that role.',
        ['输入已确认；点击对应按钮执行操作']='Input confirmed; click the corresponding button to apply it',
        ['已取消本次输入']='Input cancelled',
        ['Enter 保存 / Esc 取消 / Ctrl+V 粘贴']='Enter saves / Esc cancels / Ctrl+V pastes',
        ['Enter 确认输入 / Esc 取消']='Enter confirms / Esc cancels',
        ['已保存当前自动消息配置']='Current automatic message settings saved',
        ['请先选择预设']='Select a preset first',
        ['已替换所选预设内容']='Selected preset replaced with current settings',
        ['预设名称已更新']='Preset renamed',
        ['预设已导出']='Preset exported',
        ['预设已删除']='Preset deleted',
        ['预设已导入，请选择后加载']='Preset imported; select it to apply',
        ['设置已保存']='Settings saved',
        ['任务状态已保存']='Task status saved',
        ['任务已删除']='Task deleted',
        ['保存失败']='Save failed',
        ['该分类尚无可读取的战备']='No readable stratagems in this category',
        ['中文输入不可用：窗口 IME 上下文未就绪']='Chinese input is unavailable: the window IME is not ready',
        ['输入队列溢出，已取消并保留原值']='Input queue overflow; edit cancelled and the original value was kept',
        ['搜索已应用']='Search applied',
        ['预设数据长度无效']='Preset data length is invalid',
        ['预设校验器不可用']='Preset validator is unavailable',
        ['预设数据校验失败']='Preset data validation failed',
        ['预设数据无效']='Preset data is invalid',
        ['预设操作不可用']='Preset operation is unavailable',
        ['文件操作失败']='File operation failed',
        ['预设库格式损坏']='Preset library is corrupt',
        ['预设库序号无效']='Preset library serial is invalid',
        ['预设库数量无效']='Preset library count is invalid',
        ['预设编号无效']='Preset ID is invalid',
        ['预设编号重复或无效']='Preset ID is duplicated or invalid',
        ['预设角色无效']='Preset role is invalid',
        ['预设名称长度无效']='Preset name length is invalid',
        ['预设长度无效']='Preset length is invalid',
        ['预设名称重复或无效']='Preset name is duplicated or invalid',
        ['库内预设数据无效']='Preset data in the library is invalid',
        ['预设库含有多余数据或无效序号']='Preset library contains trailing data or an invalid serial',
        ['旧版预设无法安全复制到客机预设池']='Legacy presets cannot be safely copied to the client preset pool',
        ['预设角色无效']='Preset role is invalid',
        ['预设库超过大小限制']='Preset library exceeds the size limit',
        ['保存预设库失败']='Failed to save preset library',
        ['读取预设库失败']='Failed to read preset library',
        ['请选择主机或客机预设池']='Select a host or client preset pool',
        ['名称不能为空，且须为有效UTF-8（最多96字节）']='Name must be valid UTF-8, nonempty, and at most 96 bytes',
        ['此角色的预设名称已存在，请先重命名现有预设']='A preset with this name already exists for this role; rename it first',
        ['此角色的预设名称已存在']='A preset with this name already exists for this role',
        ['读取当前配置失败']='Failed to read current settings',
        ['预设编号已用尽']='Preset ID range is exhausted',
        ['找不到该预设']='Preset not found',
        ['所选预设不属于当前角色']='Selected preset does not belong to the current role',
        ['应用预设失败']='Failed to apply preset',
        ['导出预设失败']='Failed to export preset',
        ['读取预设文件失败']='Failed to read preset file',
        ['预设文件格式无效或过大']='Preset file format is invalid or too large',
        ['预设名称长度无效']='Preset name length is invalid',
        ['预设文件长度无效']='Preset file length is invalid',
        ['预设名称无效']='Preset name is invalid',
        ['预设格式无效或超过 1 MiB']='Preset format is invalid or exceeds 1 MiB',
        ['预设须以换行结束且使用 LF']='Preset must end with a newline and use LF line endings',
        ['预设版本无效']='Preset version is invalid',
        ['预设包含空白、重复或无效行']='Preset contains a blank, duplicate, or invalid line',
        ['预设转义无效']='Preset escaping is invalid',
        ['预设包含无效 UTF-8']='Preset contains invalid UTF-8',
        ['定时任务数量无效']='Scheduled task count is invalid',
        ['定时任务字段无效']='Scheduled task field is invalid',
        ['定时任务编号无效']='Scheduled task index is invalid',
        ['定时任务开关无效']='Scheduled task switch is invalid',
        ['旧版预设发送范围无效']='Legacy preset send scope is invalid',
        ['开关值无效']='Switch value is invalid',
        ['冷却值无效']='Cooldown value is invalid',
        ['设置值无效：']='Invalid setting: ',
        ['预设包含未知字段']='Preset contains an unknown field',
        ['规则无效']='Rule is invalid',
        ['规则开关无效']='Rule switch is invalid',
        ['规则冷却无效']='Rule cooldown is invalid',
        ['规则值无效']='Rule value is invalid',
        ['缺少设置：']='Missing setting: ',
        ['缺少定时任务数量']='Scheduled task count is missing',
        ['定时任务字段不完整']='Scheduled task fields are incomplete',
        ['定时任务名称或消息无效']='Scheduled task name or message is invalid',
        ['定时任务间隔无效']='Scheduled task interval is invalid',
        ['定时任务时间无效']='Scheduled task time is invalid',
        ['定时任务类型无效']='Scheduled task type is invalid',
        ['定时任务数量不匹配']='Scheduled task count does not match the data',
        ['未知预设']='Unknown preset',
        ['任务编号已用尽']='Task ID range is exhausted',
        ['保存定时任务失败；原任务已恢复']='Failed to save scheduled tasks; previous tasks were restored',
        ['快捷定时迁移失败；预设未应用']='Quick timer migration failed; preset was not applied',
        ['请输入事件名称']='Enter an event name',
        ['事件名称过长']='Event name is too long',
        ['请输入发送消息']='Enter a message to send',
        ['消息最多 200 字节']='Message must be at most 200 bytes',
        ['请输入 5 至 86400 的整数秒数']='Enter a whole number of seconds from 5 to 86400',
        ['请输入有效时间，例如 21:30']='Enter a valid time, for example 21:30',
        ['请选择定时类型']='Select a schedule type',
    }
    local status_prefixes={
        ['预设应用失败：']='Preset apply failed: ',
        ['预设库不可用：']='Preset library unavailable: ',
        ['设置值无效：']='Invalid setting: ',
        ['缺少设置：']='Missing setting: ',
    }

    function M.current() return state.locale end
    function M.is_chinese() return state.locale=='zh' end
    function M.set_dirty(callback) env.dirty=callback end
    function M.update(option,frame)
        if option~='zh' and option~='en' and option~='auto' then option='auto' end
        if option=='zh' or option=='en' then
            state.option=option
            if state.locale~=option then
                state.locale=option
                if env.dirty~=nil then pcall(env.dirty) end
            end
            return state.locale
        end
        frame=tonumber(frame) or 0
        if state.option~='auto' or frame>=state.due then
            state.option='auto'
            state.due=frame+120
            local ok,value=pcall(env.read_game or function() return nil end)
            local selected=ok and (value=='zh' and 'zh' or value=='en' and 'en' or nil) or nil
            if selected and selected~=state.locale then
                state.locale=selected
                if env.dirty~=nil then pcall(env.dirty) end
            end
        end
        return state.locale
    end
    function M.text(chinese,english)
        if state.locale=='zh' then return tostring(chinese or english or '') end
        return tostring(english or chinese or '')
    end
    function M.phrase(key, locale)
        local row=phrases[key]
        local selected=(locale=='zh' or locale=='en') and locale or state.locale
        return row and row[selected] or tostring(key or '')
    end
    function M.status(value)
        if type(value)~='string' or state.locale=='zh' then return value end
        local translated=statuses[value]
        if translated then return translated end
        if value:match('^战备目录读取就绪（%d+）$') then
            return 'Stratagem catalog ready ('..value:match('（(%d+)）')..')'
        end
        for prefix,english in pairs(status_prefixes) do
            if value:sub(1,#prefix)==prefix then
                local suffix=value:sub(#prefix+1)
                return english..(statuses[suffix] or suffix)
            end
        end
        return value
    end
    function M.stock_template(value, locale)
        if type(value)~='string' then return value end
        if locale=='zh' or locale=='en' then return value end
        local selected=state.locale
        if selected=='zh' then
            for zh,en in pairs(stock) do if value==en then return zh end end
            return value
        end
        return stock[value] or stock_en[value] or value
    end
    function M.stock_templates() return stock end
    function M.phrases() return phrases end
    return M
end

return build_language
