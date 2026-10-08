# 特殊标记与跨模组菜单实现计划

**Goal:** 扩展原生标记消息分类、地图标记、触发者前缀，并交付可点击的跨模组菜单接口与独立示例。
**Architecture:** 原生只读适配器产出事实事件；自动消息控制器负责开关/模板/归属/冷却；注册表负责其他模组的菜单、回调和受策略约束的发送。延续单文件游戏加载，通过构建门禁验证独立片段与内嵌一致。
**授权与规格:** 本轮用户五条需求及“小物品替换为任务建筑/战备，不再提示普通物资”的明确回答。沿用本会话持续开发与安装授权。

## 全局约束

- 不修改远端玩家身份或未经证实的发送函数参数；读取发送路径是否支持后按用户允许的前缀方案实现。
- P2P的自维护P1标签明确为估计值，不能作为真实HUD槽位/颜色的事实。
- 数据依赖仅从当前DLL、现有模组及公共一手资源核对；未知类型跳过，不猜事件枚举。
- 任务/欢迎/标记/插件自动发送共同受总开关、角色、无人房间与最短间隔约束。
- 不再自动提示普通物资/样本。保留用户其他任务和设置，迁移旧分类选择。
- 游戏仍使用已有槽313，336属于SmoothBoot。示例单独构建，部署前验证槽位归属。
- 所有新行为先失败回归、再实现、独立审查、完整测试后打包；离线证据不替代实机验收。

## 任务1：特殊目标与地图事件

Files: src/ping_events.lua, work/standalone/tests/test_ping_events.py, docs/PING-CLASSIFICATION-0.7.0.md
Consumes: 现有env.base/read/context/session/emit；完整8字节creator_id。
Produces: event.category/target/creator_id/key/kind以及坐标事件的position字段。

- [x] 从当前组件/资源路径记录核实非法广播、TCS、激光大炮、堡垒坦克等实际目标ID。
- [x] 测试证明战备/任务建筑分类正确、普通补给不再产生事件。
- [x] 从原生记录+04/+08/+0C读取坐标；验证creator、有限浮点、现有基线、重标记与切房。
- [x] 明确战术地图图钉与普通地面ping是否共用记录，分别测试已证实的事件路径。
- [x] 未知实体先尝试游戏本地化标记文本（只有已证实接口可用）；否则保留明确资源目录中文名。

## 任务2：自动策略、提示与触发者

Files: src/chat_automation.lua, src/peer_identity.lua（如需）, src/auto_chat.lua, tests/test_chat_automation.py, tests/test_panel_interaction.py
Consumes: 原生事件、游戏会话与peer名单、已证实名字/颜色信息。
Produces: 持久化的新分类设置、触发者前缀、{类别}/{目标}/{触发者}/{位置}模板。

- [x] 删除小物品分类入口，新增任务建筑、战备提示和地图标记选项，按用户回答停止普通补给提示。
- [x] 把冷却文案改为“自动消息最短间隔”，解释共用范围及0秒关闭限制。
- [x] 发送身份仍遵循已证实游戏路径；优先安全显示触发者姓名缩写，颜色需确认聊天富文本确实支持。
- [x] 测试peer匹配、匿名/乱码/缺失名字回退、模板安全、队列/开关/重启迁移及共用冷却。
- [x] 事件在排队和发送前重新确认归属与会话，离队/切房不误标识。

## 任务3：开放菜单接口和真实示例

Files: src/plugin_registry.lua, src/examples/interface_demo.lua, src/auto_chat.lua, tests/test_plugin_registry.py, tests/test_plugin_integration.py, tools/build_interface_demo.py, docs/PLUGIN-API.md
Consumes: registry/host.note/host.send/host.context；宿主统一发送策略。
Produces: HD2AutoChatPlugins / HD2AutoChatAPI v2；注册名菜单、draw/on_click/on_event/revision/send接口。

- [x] 测试注册、重复/无效/数量限制、注销、回调失败隔离、revision刷新及事件副本。
- [x] 注册name/title成为设置旁独立菜单，超出一行可翻页；UTF8标题不截断字节。
- [x] u.button/u.region点击走对应on_click，接口坐标约束在菜单内容区域。
- [x] 示例注册“接口示例”，展示开关、按钮、事件计数及受宿主策略约束的发送；默认不自动刷消息。
- [x] 早加载示例通过HD2AutoChatPending暂存，晚加载直接注册；兼容现有v1注册方式。
- [x] 集成测试实际加载示例、点击菜单/按钮、触发事件、断言游戏发送函数调用，并检查故障示例不破坏设置。
- [x] 打包独立示例zip、更新API文档和预览，运行完整门禁并核对安装源码。

## 完成证据与边界

228项离线测试通过；主包与独立示例已构建、校验、安装。见 docs/AUTOMATION-0.7.0-VERIFICATION.md。
非法广播采用已证实的原生类型+游戏本地化链，不把未证实的资源ID猜作非法广播。
原生名称、真实队色显示、地图关闭状态与示例事件计数仍需重启后实机验收；离线完成不冒充实机完成。
