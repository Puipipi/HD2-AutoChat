# AutoChat 菜单接口 v2

运行依赖：Bingus Shared Loader v15+、AutoChat 0.7.0。示例为独立 addon：
`src/examples/interface_demo.lua`，资源 `mods/codex/auto_chat_demo`，GUID `a1000000-0000-4000-8000-000000000023`。
构建：`python -B tools/build_interface_demo.py`。完整可导入包在 `dist/AutoChat-Interface-Demo-0.7.0.zip`。

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
`id` 是1–64字节英文/数字/下划线/点/连字符；`name` 是1–96字节显示名。ID不可重复，最多16项。
`draw` 必填，其余回调可选。`register(spec)` 返回 entry 或 `nil,原因`；`unregister(id)` 注销。
菜单显示在“设置”旁，较多时用左右箭头翻页。显示名称过长会截短，注册名保留。

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

`u.palette` 提供配色。button/region 必须完全在内容区内，越界拒绝注册。
key建议仅用英文/数字/下划线。按钮在按下、松开都位于同一控件时触发当前菜单的 `on_click(key,api)`。
draw只负责绘制，不能在其中每帧发送。revision返回改变后的数字/布尔值/短字符串，宿主据此刷新。

## 发送与事件

回调中的 `api={version=2,api_version=2,id,context(),send(text)}`。
`api.send(text,creator_id?)` 返回 `成功布尔值,原因`，消息非空、无NUL、最多512 UTF-8字节。
总开关、主客机范围、无人房间、每人自动消息最短间隔、会话及原生聊天可用性全部生效。
AutoChat 0.7.9起，接口自动使用当前主机/客机预设，包括消息输出方式。
仅自己可见时返回 `true,'local'`，消息只加入本机聊天；小队发送继续返回 `true,其他玩家数`。
本地不可用不会回退公屏，身份未确认时返回false。不要通过直接调用游戏发送函数绕开宿主的输出选择。
AutoChat 0.7.1起，可传入当前事件的完整16位hex `creator_id`，按该触发者计时并替换名字模板。
例如 `api.send('欢迎 {玩家名}（{缩写}，{编号}号）',event.creator_id)`；触发者离队或ID无效会拒绝。
不传时按本机玩家计时并代入本机信息，旧版调用保持兼容。
`{玩家名}/{名字}/{触发者}`为名字，`{缩写}`为HUD缩写，`{编号}`为真实队伍槽号；未知变量保留。
失败时接口不自动排队，插件按返回原因决定何时重试；勿每帧重试。
不要保留旧回调中的 api 发送器，切房或注销后会拒绝；在当前回调中获取新的 api。
注册表还提供 `send(id,text,creator_id?)`、`click(id,key)`，供同进程直接调用。

当前公开 `on_event` 事件：

| 字段 | 内容 |
| --- | --- |
| `type` | `ping` |
| `category` | `building / stratagem / medium_enemy / large_enemy / giant_enemy / map` |
| `target` | 游戏名称或已核实资源名 |
| `creator_id` | 完整16位大写十六进制peer ID；共享调用无法归属时缺省，检查anonymous；不要转Lua number |
| `position` | `{x,y,z}` 世界坐标，可选 |
| `key / id` | 本次标记唯一标识 |
| `kind / source` | 原生类型及 `target / native_marker / tactical_map / map_objective / stratagem_call / mission_stratagem` |
| `action` | 可选：`summon` 表示战备召唤，`use` 表示原地执行任务战备，`mark` 或缺省表示标记；旧接口兼容 |
| `objective_name / objective_kind / objective_importance` | 0.7.3地图任务可选字段：游戏名称；`primary / prerequisite / optional / tactical / unknown`；原生当局属性整数 |
| `anonymous / stratagem_id` | 0.7.8任务战备字段：共享成功记录无法归属时anonymous=true；stratagem_id为稳定战备ID |
| `resource / target_id / localization_key / slot` | 可选调查字段 |

这是经过归属与会话检查的本人或队友新标记、战备召唤及任务执行。共享调用不能证明触发者时不提供creator_id，插件应显示“小队”，不可把缺省ID代入本机冒充调用者。普通物资、地面空点、地图空白点不发布，进入房间时已有标记只建基线。
地图任务字段来自目标实体与当局任务记录，不按名称猜分类；撤离区没有任务字段。
订阅者存在时，即使宿主自动消息关闭也读取并发布观察事件，但调用发送仍受总开关限制。
每个插件接收独立的有界事件副本；某个插件改事件不会影响其他插件或自动消息。
回调异常被隔离并记日志，draw故障会移除该菜单，其他回调故障保留菜单并限量记日志。
这些接口用于合作模组，不是隔离不可信Lua的沙箱。

## 示例验收

开启独立“接口示例”包并部署，重启后按K，设置旁应出现“接口示例”。
计数默认关闭：打开计数后，请队友标记一个受支持目标或地图图钉，计数应增加。
点击“立即发送测试消息”走正常小队发送；短间隔连续点击会显示等待原因。
关闭自动发送总开关后再点击，应被拒绝。加载和切换菜单均不自动发送。
示例状态只保留到退出游戏。离线集成测试实际加载此源码并点击宿主按钮，尚需实机验收。
