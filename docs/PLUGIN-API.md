# AutoChat 菜单接口 v2，revision 4 扩展

运行依赖：Bingus Shared Loader v15+、AutoChat 0.8.6 或更新版本（当前推荐 1.0.0）。协议保留 `version=2` 与 `api_version=2`，当前 `api_revision=4` 并通过 capabilities 声明可选能力；因此只检查 `api_version==2` 的旧插件仍可注册并使用原有发送调用。revision 4 示例包：
`src/examples/interface_demo.lua`，资源 `mods/codex/auto_chat_demo`，GUID `a1000000-0000-4000-8000-000000000023`。
构建：`python -B tools/build_interface_demo.py`。示例输出为 `dist/AutoChat-Interface-Demo-1.0.0.zip`；它与 AutoChat 主包分开构建、启用和部署。

## 注册与加载顺序

```lua
local state = {count=0,revision=0,result='等待点击'}
local spec = {id='my_mod',name='我的模组'}
spec.draw = function(u, ctx, api)
    u.text(state.result, 20, 20, 16)
    u.button('send', '发送测试', 20, 60, 220, 32, true)
end
spec.on_click = function(key, api)
    if key ~= 'send' then return false end
    local ok, why = api.send('来自我的模组')
    state.result = ok and '已发送' or tostring(why)
    state.revision = state.revision + 1
end
spec.on_event = function(event, api)
    if event.type == 'ping' then
        state.count = state.count + 1
        state.revision = state.revision + 1
    end
end
spec.revision = function() return state.revision end
local registry = rawget(_G,'HD2AutoChatAPI')
if registry and registry.api_version == 2 then
    local entry, why = registry.register(spec)
else
    _G.HD2AutoChatPending = _G.HD2AutoChatPending or {}
    _G.HD2AutoChatPending[spec.id] = spec
end
```

`HD2AutoChatPlugins` 与 `HD2AutoChatAPI` 指向同一注册表；旧版 `title` 与 `draw(u,ctx)` 仍兼容。
`id` 是1–64字节英文/数字/下划线/点/连字符；`name` 是1–96字节显示名。`name_en` 可选，也是1–96字节，并遵循同样的非空白、无控制字符校验。自动语言为英文且存在 `name_en` 时，标签显示英文名；否则显示 `name`。注册身份 `id`、entry 的 `title`/`name` 始终保留原值。ID不可重复，最多16项。
`draw` 必填，其余回调可选。`register(spec)` 返回 entry 或 `nil,原因`；`unregister(id)` 注销。客户端应检查所需的 capability，不要把 `api_version` 改成 3，否则旧版严格检查 `==2` 的插件会停止工作。
`on_event` 是可选回调；只有确实需要实时游戏事件时才注册。注册该回调会启用宿主事件采样，即使插件在回调内部忽略事件也一样；只提供菜单和自定义发送的插件应省略它。
菜单显示在“设置”旁，较多时用左右箭头翻页。显示名称过长会截短，注册名保留。
插件是另一个独立 Lua addon；若宿主已初始化，可直接调用公开的 `HD2AutoChatAPI.register`。若插件更早加载，则把 spec 暂存到 `HD2AutoChatPending[id]`，宿主初始化时会接管。两种路径都无需固定加载顺序。仓库没有 Bingus Shared Loader 或 Arsenal 的资源调度实现，因此不能据管理器列表位置推断运行时先后；插件应始终实现这两条注册路径。ID已注册时拒绝重复注册，不会产生重复菜单。插件自行编写消息文本并在按钮回调中调用 `api.send(text)`，无需接触游戏内存或聊天原生函数。宿主不提供插件文本输入框；需要让用户配置消息时，插件应自行保存设置。当前示例发送插件自己生成的自定义消息。

## 绘制与点击

坐标原点是当前菜单内容区左上角，按 Armory 的面板单位计算，缩放由宿主完成。
使用 `u.content_w / u.content_h` 排版；旧 `u.w / u.h` 保留整框1000×990含标题与标签。

| 方法 | 参数 |
| --- | --- |
| `u.text` | `(文本,x,y,字号,颜色?,最大宽度?)` |
| `u.rect` / `u.border` | `(x,y,宽,高,颜色?,层级?)` |
| `u.button` | `(key,文本,x,y,宽,高,启用?,选中?)` |
| `u.region` | `(key,x,y,宽,高)`，自绘控件的点击区 |
| `u.note` | `(文本)`，记入宿主日志 |
| `u.line` | `(x1,y1,x2,y2,色彩,层级,宽度?)` |
| `u.image` | `(已加载材质hash,x,y,宽,高,色彩?,层级?)` |
| `u.icon` | `(已加载材质hash,x,y,尺寸,色彩?,层级?)` |

`u.palette` 提供配色。button/region 必须完全在内容区内，越界拒绝注册。
key建议仅用英文/数字/下划线。按钮在按下、松开都位于同一控件时触发当前菜单的 `on_click(key,api)`。
draw只负责绘制，不能在其中每帧发送。revision返回改变后的数字/布尔值/短字符串，宿主据此刷新。
发送顺序是：插件注册并显示标签 → 用户打开插件标签 → 点击插件按钮 → 插件在 `on_click` 中调用当前回调提供的 `api.send`。不要在 `draw` 中发送，因为宿主会重复调用绘制回调。按钮状态可用插件自己的 `revision()` 更新。

## 发送与事件

绘图回调收到 `draw(u,ctx,api)`。`ctx` 坐标原点是内容区左上角；`content_w/content_h` 是可用边界。`ctx.language` 与 `u.language` 是宿主当前自动语言，值为 `zh` 或 `en`。它们用于选择插件自己的固定 UI 文案；用户自定义文本应保持原样。`u.image` 和 `u.icon` 只接受 16 位十六进制的已加载游戏材质标识，不接受任意文件路径或自行加载的文件图片。宿主可能在 `u.loaded_icon` 提供当前 catalog 中已验证加载的一个材质；它是可选值，缺失时应显示文字或跳过绘制。其他材质只有在插件已从可信来源取得且确认加载后才能传给绘图函数。越界或未加载资源会返回 `false,reason`。

`u.line` 用受边界限制的矩形近似线段，不是原生矢量线条。水平和垂直线使用一个矩形；斜线由离散矩形点组成，最多 512 个点，超长或越界线段会被拒绝。

回调 API 的基础字段是 `{version=2,api_version=2,api_revision=4,capabilities,id,context(),settings(),send(...)}`。当前 capabilities 名称为 `independent_send`、`settings`、`plugin_ui`、`plugin_presets`；逐项检查对应字段，不能只凭 revision 假定功能可用。
`api.settings()` 返回当前已确认角色的只读配置副本，含 `role`（`host` 或 `client`）、`language`（`zh` 或 `en`，宿主界面语言）、`message_language`（`auto`、`zh` 或 `en`，预设消息模式；当前没有单独的界面选项）、该预设的可序列化字段（如 `enabled`、`allow_solo`、`cooldown`、`output`、各类 `ping_*` 和快捷计时器字段）、深拷贝 `rules`，以及任务数组 `tasks`（每项含 `name`、`mode`、`time`、`message`、`enabled`）。`language` 自动跟随受支持的游戏语言设置；它不会更改 `message_language`、消息、规则或任务。新安装的默认消息使用英文，缺少该字段的旧配置以 `message_language='auto'` 兼容读取。两个不可删除的内置预设固定命名为“中文默认预设”和“English Default Preset”，分别使用固定 ID `builtin-host-zh`、`builtin-host-en`、`builtin-client-zh`、`builtin-client-en`，主机与客机各有独立内容；只有用户手动应用预设时才替换当前角色配置。未确认角色返回 `nil,'role unavailable'`；无效会话或已注销的回调返回 `nil,reason`。快照不可用于修改宿主配置，也不暴露玩家、聊天、运行时对象或回调引用。

### 插件预设 opt-in hooks

插件默认不参与主机/客机命名预设。若插件要把自己的设置随 AutoChat 预设保存，注册 spec 可选提供完整四项 `preset` hooks；只提供部分函数会使注册失败：

```lua
spec.preset = {
    capture = function(role) return data_string end,
    validate = function(data_string, role) return true end,
    apply = function(data_string, role) return true end,
    restore = function(previous_data_string, role) return true end,
}
```

`role` 是 `host` 或 `client`。`capture` 返回插件自己的数据字符串；校验、应用和恢复必须返回 `true`，失败可返回 `false,reason` 或抛出错误。宿主按稳定插件 `id` 保存各插件数据。hooks 只在用户保存、替换或应用预设时调用，不会进入 `draw`、每帧更新或游戏事件热路径。插件应严格校验自有格式和版本；这些回调只处理数据，不发送消息或执行配置内容。当前可移植 profile 为 v5，使用 `plugin_count` 记录插件数据条数，并以 `plugin.<id>=...` 保存按字节转义的不透明 blob；ID 为 1–64 字节英文/数字/下划线/点/连字符。blob 可包含非 UTF-8 字节、NUL 和换行；v1–v4 没有插件 blob。单个 profile 总体最多 1 MiB，超限会拒绝保存或应用。

应用前宿主先校验所有当前已注册且 opt-in 插件的数据，并捕获它们各自的旧状态；只有预检成功才按插件 ID 顺序调用 `apply`。若 hook 执行期间插件注册发生变化，预检会失败且不会开始应用。某个插件或 AutoChat 自身预设应用失败时，宿主按逆序调用已尝试插件的 `restore`，并报告无法恢复的插件 ID。插件应让 `restore` 安全处理部分应用失败，并在失败时返回明确原因。没有对应 blob 时不会调用 hook；缺失、未 opt-in 或未知插件 ID 的数据会保留，不会被擅自应用或丢弃。两个内置默认预设只保存 AutoChat 默认配置，不会更改插件状态。

随包“接口示例”addon 实现了这些 hooks，可离线验证主机和客机分别保存模式、独立开关、冷却、输出与模板索引；发送结果、悬停和提示等临时 UI 状态不写入预设。示例不会自动发送或订阅实时事件。

`api.send(text,creator_id?,options?)` 返回 `成功布尔值,原因`，消息非空、无 NUL、最多 512 UTF-8 字节。经自动发送路径成功发送的正文会规范为恰好一个开头换行，插件无需自行添加；游戏聊天仍以本地玩家为发送人。旧版 `api.send(text,creator_id?)` 保持 API v2 行为：遵守总开关、当前角色配置、无人房间许可、宿主发送冷却、会话及原生聊天可用性，并采用当前主机/客机预设的输出方式。

revision 3 的 `options` 只接受 `policy`、`enabled`、`cooldown`、`cooldown_key`、`allow_solo`、`output`。省略 `options` 或使用 `policy='inherit'` 时继承宿主设置；继承模式不接受覆盖字段，若同时传入会拒绝请求。`policy='independent'` 使用插件自己的启用状态、冷却和输出策略，可不受 AutoChat 主开关及宿主全局冷却影响，但仍执行会话、角色、触发者、原生发送器和消息合法性检查。独立选项默认 `enabled=true`、`cooldown=0`、`cooldown_key='default'`、`allow_solo=true`、`output='inherit'`。`cooldown` 以秒计；`cooldown_key` 必须是 1–64 字节且不含控制字符。同一插件、触发者与 key 共用一个桶；每个插件在当前会话最多保留 128 个未过期的正冷却桶，`cooldown=0` 不占桶。过期桶在下一次发送时清除；容量满时不驱逐有效桶，而是拒绝新桶。宿主当前使用 `os.time()`，精度为 1 秒。请求不会排队，失败后由插件决定何时重试，不要逐帧重试。

```lua
local ok, why = api.send('来自插件的消息', nil, {
    policy = 'independent',
    enabled = true,
    cooldown = 5,
    cooldown_key = 'my_mod_alerts',
    allow_solo = true,
    output = 'local',
})
```

`output` 接受 `inherit`、`local` 或 `public`。`inherit` 使用当前角色预设，`local` 仅自己可见，`public` 发到小队。成功的本地发送返回 `true,'local'`；小队发送返回 `true,其他玩家数`。本地输出失败不会回退到公屏。请勿直接调用游戏发送函数绕过宿主校验。
AutoChat 0.7.1起，可传入当前事件的完整16位hex `creator_id`，按该触发者计时并替换名字模板。
例如 `api.send('欢迎 {玩家名}（{缩写}，{编号}号）',event.creator_id)`；触发者离队或ID无效会拒绝。
不传时按本机玩家计时并代入本机信息，旧版调用保持兼容。
`{玩家名}/{名字}/{触发者}`和`{player}/{player_name}/{name}`为完整玩家名；仅在格式化输出时整体加一对方括号，例如 `[Alice]`，源名字已经整体带方括号时不会重复添加，也不会改动原始玩家名称。`{缩写}/{short}/{abbr}`为HUD缩写，`{编号}/{slot}/{number}`为真实队伍槽号。插件 `api.send` 与欢迎、定时消息支持这些玩家变量；自动标记、召唤与任务模板还支持 `{类别}/{category}`、`{目标}/{target}/{stratagem}/{战备}`、`{动作}/{action}`、`{任务名}/{objective}/{task}`、`{任务类型}/{objective_type}/{task_type}`和`{位置}/{position}`。类别等事件变量仅在标记、召唤和任务事件中有值；玩家变量也适用于欢迎、定时消息和插件发送。中文、英文变量可混用，未知变量原样保留。变量和目标名称按当前角色预设的消息语言选择，不随UI语言变化。详细示例见[玩家模板变量说明](PLAYER-TEMPLATES.md)。
AutoChat 自身按 `ping_sender_color` 为完整的 `[玩家名]` 与标记缩写前缀着色；插件消息会替换完整玩家名并加方括号，但不会自动着色。
失败时接口不自动排队，插件按返回原因决定何时重试；勿每帧重试。
不要保留旧回调中的 api 发送器，切房或注销后会拒绝；在当前回调中获取新的 api。
注册表还提供 `send(id,text,creator_id?,options?)`、`settings(id)` 和 `click(id,key)`，供同进程直接调用。`settings(id)` 返回相同的只读配置副本；传入不存在或未注册的 ID 会返回 `nil,reason`。直接调用 `send` 与 callback API 使用相同 options 和发送校验。
继承模式按宿主当前角色设置选择输出，并遵守会话、总开关、宿主发送冷却及 UTF-8 字节限制；独立模式只绕过总开关和宿主全局冷却，其他宿主校验仍生效。自定义消息可以包含宿主支持的名字占位符，发送时由宿主格式化。

当前公开 `on_event` 事件：

| 字段 | 内容 |
| --- | --- |
| `type` | `ping` |
| `category` | `building / stratagem / supplies / small_enemy / medium_enemy / large_enemy / giant_enemy / flying_enemy / map`；飞行优先于体型 |
| `target` | 游戏名称或已核实资源名 |
| `creator_id` | 完整16位大写十六进制peer ID；共享调用无法归属时缺省，检查anonymous；不要转Lua number |
| `position` | `{x,y,z}` 世界坐标，可选 |
| `key / id` | 本次标记唯一标识 |
| `kind / source` | 原生类型及 `target / native_marker / tactical_map / map_objective / stratagem_call / mission_stratagem` |
| `action` | 可选：`summon` 表示战备召唤，`use` 表示原地执行任务战备，`mark` 或缺省表示标记；旧接口兼容 |
| `objective_name / objective_kind / objective_importance` | 0.7.3地图任务可选字段：游戏名称；`primary / prerequisite / optional / tactical / unknown`；原生当局属性整数 |
| `anonymous / stratagem_id` | 0.7.8任务战备字段：共享成功记录无法归属时anonymous=true；stratagem_id为稳定战备ID |
| `stratagem_rule_id / stratagem_group / stratagem_ambiguous` | 0.8.0：同名且呼叫方式相同的变体共用设置规则ID；分组为red/blue/green/other；无法唯一确认具体变体时ambiguous=true且不伪造stratagem_id |
| `resource / target_id / localization_key / slot` | 可选调查字段 |

这是经过归属与会话检查的本人或队友新标记、战备召唤及任务执行。共享调用不能证明触发者时不提供creator_id，插件应显示本地化的“小队 / Squad”，不可把缺省ID代入本机冒充调用者。可确认身份的普通物资以 `supplies` 类别发布；宿主普通物资自动提醒默认关闭，但插件订阅者仍可观察这类事件。未能确认身份的地图物资、地面空点和地图空白点不发布，进入房间时已有标记只建基线。
地图任务字段来自目标实体与当局任务记录，不按名称猜分类；撤离区没有任务字段。
订阅者存在时，即使宿主自动消息关闭也读取并发布观察事件。继承模式的调用发送仍受宿主总开关限制；独立模式按其 `enabled` 与冷却策略决定是否发送，并继续经过其他宿主校验。预设池、任务列表和规则没有条目数量上限，但持久化文件、预设payload及各字段仍受显式字节大小和格式校验限制；插件事件队列、菜单数和独立冷却桶也有各自的运行时容量边界。
每个插件接收独立的有界事件副本；某个插件改事件不会影响其他插件或自动消息。
回调异常被隔离并记日志，draw故障会移除该菜单，其他回调故障保留菜单并限量记日志。
这些接口用于合作模组，不是隔离不可信Lua的沙箱。

## 示例验收

开启独立“接口示例”包并部署后，设置旁应出现“接口示例”。页面展示主设置快照，并提供继承/独立模式、独立启用开关、0/5 秒独立冷却、继承/仅自己输出、模板切换与手动发送。继承模式受主设置控制；独立模式用示例自己的启用状态和冷却，仍通过宿主校验。关闭示例独立开关会在调用 API 前阻止发送。加载和绘制不会发送，示例不注册 `on_event`。
页面的图标来自宿主可选的 `u.loaded_icon`。若当前无已加载资源，页面应显示友好提示。离线 contract 测试可验证参数传递、无事件订阅和打包身份；它不能证明 Loader 或游戏内绘制、图标加载或多人发送。
