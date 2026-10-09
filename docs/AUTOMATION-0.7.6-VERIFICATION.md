# AutoChat 0.7.6 — 空点过滤、召唤消息与任务旗帜（2026-10-09）

## 行为

- 普通地面 kind 0 与地图空白 type 7 不发布事件、不排队发送。未确认类型的 HUD map 记录也跳过。实际同步任务 type 1 和撤离区 type 6 继续处理；任务名未就绪仍保留重试。
- 战备召唤独立开关 `ping_summon`，独立模板 `summon_message` 默认 `{玩家名}召唤了{目标}`。手动标记落地战备仍使用原模板与 `ping_stratagem` 开关。二者受标记总开关、角色条件和每人最短间隔约束；关闭召唤开关也取消其待发队列。
- `{动作}` 为“召唤”或“标记”，面板同时展示两个消息输入框及变量提示。既有自定义标记模板、任务与设置不被改写。
- 新增任务旗杆 `9A1F728716DA05B5` 与任务旗帜 `9D3A7E11095E3355` 的建筑目录兜底，分别显示“超级地球旗杆”“任务旗帜”。保留 CQC-1 武器的战备分类。
- 插件事件增加可选 `action` 与 `source=stratagem_call`，保留旧事件结构兼容。

## 根因与依据

既有读取把战备召唤产生的持续标记也作为普通标记排队，所以句式错误。此前只读实机记录中，重新补给/补给小车的召唤记录均为 kind 20、duration 9999、flags 0x2200；手动落地补给为 kind 10、duration 8、flags 0x600，落地补给车为 kind 13、duration 8、flags 0x1200。
当前 DLL `13D0A90` receiver 中，战备管理器查找成功后在 `13D1447` 设置 0x2000；kind 20 不在短时组表中，使用 9999 常量。
因此只在 kind 20、duration 9999 且 0x2000 置位时归为召唤，不按名字或类别推断。0x2000 纳入快照前后校验，变化时丢弃该批事件。

旗杆缺少静态目录条目；当游戏没有提供可读名称时，旧实现无法分类。当前 EntityComponentMap 与 FileDiver 路径核对得到 `content/objectives/obj_common/raise_flag/hellpod_flag` 和 `carry_flag`，均为 Spottable 任务实体；地图区域资源不冒充现场可标记建筑。
资料：[EntityComponentMap](https://github.com/Darctor/Helldivers2_RawData/blob/main/Data/settings/EntityComponentMap.json)、[FileDiver hashes](https://github.com/xypwn/filediver/blob/master/hashes/hashes.txt)、[历史 Spottable 数据](https://github.com/shalzuth/HelldiversData/blob/master/data/entities/SpottableComponentData.json)。

0.7.4 曾支持普通地点提示；本版依用户最新要求取消。任务与撤离区是有具体含义的图标，继续保留。

## 验证与限制

回归先复现缺失 action、召唤错误模板、空点仍发事件、任务旗帜资源漏报，再修改实现。测试覆盖持续召唤与短时物品区别、缺少召唤标志的 kind 20、开关独立与关闭后取消队列、模板保存、真实面板点击编辑、空点排除、任务关联和撤离区坐标。

完整 274 项测试通过，69.449秒，0失败。日志：`work/deploy/tests-0.7.6.txt`。LuaJIT、内嵌片段一致性、FFI/只读门禁与无脚本归档检查通过。离线面板绘制图确认输入框和变量说明可见，不等同于游戏字体截图。

用户再次现场标记旗杆后，外部只读采样确认 kind 18、target 528、resource 9A1F728716DA05B5、flags 0x1200、duration 8、localization key 3585962803；后者文本为“特殊地点”。因此对已确认的旗杆/任务旗帜资源，泛地点 key 使用具体资源名；未知目标继续保留原生标签，不猜旗杆。新回归先复现“特殊地点”覆盖具体旗杆名，再验证具体名称。新版游戏内最终发送仍需重启加载后验收；已有标记只建基线，需重新操作。

新一轮外部只读采样将同一份受测读取片段用于运行中的游戏数据，补给型快速侦察载具、轨道120MM高爆弹火力网、轨道激光炮、“飞鹰”500KG炸弹均分类为 `action=summon / source=stratagem_call`，无采样错误。这验证实际记录能被新分类读取，不等同于新版模组已发送聊天。

## 构建与安装

主包 `AutoChat-0.7.6.zip`：78488字节，SHA256 `6cf3dae99c8f215bcccc984ae0eb83130cf76ee34761324ee07931407b0cf41b`。
Payload：225040字节，SHA256 `8ad6c035065bbb044784863f5e2bcdeca403ab2e22767df54f6c60c444c25b87`。

ZIP CRC、归档源码与受测源码逐字节一致性通过。游戏槽313已原子替换，当前 GUID 对应管理器库的5个归档文件与ZIP一致；1044个其他层文件、5个用户偏好文件和管理器索引与安装前相同。已备份旧游戏层、管理器包和偏好。正在运行的游戏仍使用先前加载内容，新版下次启动生效。

