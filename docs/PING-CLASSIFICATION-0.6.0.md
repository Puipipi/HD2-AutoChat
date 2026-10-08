# 标记分类依据与范围 — 2026-10-09

本版本按实际标记目标的资源ID分类，图标资源只用于核对视觉类别，不作为数值事件枚举。
Custom UI和Better Map Markers只替换材质/贴图；未复制或分发它们的资源。

## 读取链

支持Steam build25480438，game.dll SHA256：
`2E2C3B7C2500646DADD5F2B4C6E0504DBB7E7896139F64CDDC0D1813C718F51E`。
调用方先校验现有五段聊天签名及PE时间戳0x6AB3B43F。
原生环：ptr(game+0x347CE30)，活动byte0，head+8/tail+12，容量128，记录步长0x58。
记录kind+0，duration+0x10，age+0x14，creator entity+0x18，target entity+0x20。
通用实体根ptr(game+0x346BF98)，实体hash root+0xF1AEB0，描述数组root+0xF32F18，步长24。
它是通用实体注册表；HealthComponentData目录只用于敌人体型事实，物品不需要拥有Health组件。

归属：玩家管理器ptr(game+0x3326468)，完整peer ID八字节，描述/角色网络ID与通用实体身份交叉核对。
自己的标记、无法归属的标记、kind0地面和kind24快捷语音、过期/未知目标跳过。
每次读取受地址、长度、容量、探测步数及2048次读取预算限制；只经ReadProcessMemory访问游戏内存。
读后复核会话token、native指针、玩家绑定、实体映射以及标记稳定字段/age，变化则丢弃整批。
启动/重新开启/切房只建立现有标记基线。目标暂未加载时保存待解析状态，标记过期即丢弃。

## 已支持的范围

| 开关 | 已核实资源 |
| --- | --- |
| 小物品 | 19种：弹药盒、手榴弹包、针剂、样本瓶、普通/稀有/超级样本 |
| 中型敌人 | 41种敌人资源，Health.unit_size=1 |
| 大型敌人 | 33种敌人资源，Health.unit_size=2 |
| 巨型敌人 | 5种敌人资源，Health.unit_size=3 / Massive |
| 任务地点 | 5种可标记任务实体，见下表 |

| 任务资源ID | 已核实路径 / 名称 |
| --- | --- |
| B1D938C07E30C5DB | content/objectives/obj_common/icbm_silo/icbm_silo / 洲际导弹发射井 |
| EAE962D85C0C2D4A | content/objectives/obj_common/oil_pump/oil_pump / 抽油钻机 |
| 3A28A51BAA029E1A | content/objectives/obj_common/oil_pump/oil_pump_active / 工作中的抽油钻机 |
| A3D5F183F8A2B768 | content/objectives/obj_common/seaf_artillery/seaf_drop_off / SEAF火炮装填点 |
| DF3C4F91E298BFA4 | content/objectives/obj_bugs/central_core/central_core_drill_01 / 虫巢核心钻机 |

任务覆盖实际有目标实体的标记，纯地图坐标图钉无法据此分类。未知资源跳过。
排除教程实体、损坏样本和non_objective_oil_pump_animated装饰模型。
所有新增分类与归属行为经过合成内存测试，仍需真实队友标记验收。

## 主要证据

- [G60 native_ping](https://github.com/etxp/HD2-G60-Smart-Targeting/blob/main/src/g60/native_ping.lua)及[native_target_data](https://github.com/etxp/HD2-G60-Smart-Targeting/blob/main/src/g60/native_target_data.lua)：环与通用实体布局。
- [HD2Runtime event_world](https://github.com/SkyeShade/HD2Runtime/blob/master/runtime/event_world.lua)及[event_natives](https://github.com/SkyeShade/HD2Runtime/blob/master/domains/event_natives.lua)：同DLL指纹的原生指令校验、玩家归属字段。
- [RawData EntityComponentMap](https://github.com/Darctor/Helldivers2_RawData/blob/main/Data/settings/EntityComponentMap.json)：Spottable、Interactable、Loot及Objective组件成员关系。
- [RawData Hash.csv](https://github.com/Darctor/Helldivers2_RawData/blob/main/Data/Hash.csv)与[EncyclopediaEntry](https://github.com/Darctor/Helldivers2_RawData/blob/main/Data/entities/EncyclopediaEntryComponentData.json)：物品身份。
- [RawData Health](https://github.com/Darctor/Helldivers2_RawData/blob/main/Data/entities/HealthComponentData.json)与[AiEnemy](https://github.com/Darctor/Helldivers2_RawData/blob/main/Data/entities/AiEnemyComponentData.json)：敌人与体型交叉事实。
- [FileDiver路径清单](https://github.com/xypwn/filediver/blob/master/hashes/hashes.txt)：实际任务路径身份，排除仅显示名误导的模型。

原生代码参考许可证随源片段保留，见THIRD_PARTY_NOTICES.md。
