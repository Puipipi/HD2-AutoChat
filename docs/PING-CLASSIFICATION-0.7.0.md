# 0.7.0 标记读取与归属依据

目标仍为 Steam build25480438，game.dll SHA256：
`2E2C3B7C2500646DADD5F2B4C6E0504DBB7E7896139F64CDDC0D1813C718F51E`。
五段发送签名和PE时间戳0x6AB3B43F不匹配时不使用这些布局。旧读取链见 PING-CLASSIFICATION-0.6.0.md。

## 分类

| 设置 | 范围 |
| --- | --- |
| 任务建筑 | 旧5种任务实体、6种TCS实体；原生18/19特殊标记且游戏名称解析成功的其他目标 |
| 战备提示 | 34种支援武器、LAS-98装备架、堡垒坦克；原生20特殊标记且游戏名称解析成功的其他目标 |
| 中型/大型/巨型敌人 | 41/33/5种敌人资源，沿用当前Health.unit_size事实 |
| 地图标记 | 原生21战术地图图钉，允许没有实体，保存XYZ坐标 |

合计126种静态资源。普通弹药/针剂/手雷/样本19种旧资源显式排除，即使有特殊kind和本地化名也不提示。
未知非特殊目标跳过；特殊标记没有可读名称且不在目录中时不猜名字，在有效期内重试。
TCS目录名保留上下文：若游戏只给出“基础终端”等通用名，显示“TCS 任务终端 / 游戏名”。

| 资源ID | 已核实身份 |
| --- | --- |
| D54B9505C0F72873 | LAS-98 激光大炮 |
| 16474112801385B6 | 堡垒坦克，友方战备载具 |
| FDE262593307CA2F | LAS-98装备架 |
| 319388D1D8ACB8F3 / A09A19371FECD6A3 | TCS终端 |
| 0722B3A72ADE6CB1 | TCS主塔 |
| BF908A82B8E787AC / C3D9B291BD97B935 / 6FDCD0D7F8EAF267 | TCS支撑建筑/支柱 |

非法广播没有被未证实的静态ID强行命名；它依靠原生任务标记类型与游戏本地化文本。
这条链已用“非法广播”合成事件验证，实际游戏该目标是否携带对应类型/文本仍待队友标记验收。

## 地图与名称

当前DLL 18BA34A→18BA38E发出kind21，13D0A90接收；历史HudMarkerType枚举仅作交叉参考。
记录position+04/+08/+0C、creator+18、localization_key+34。地图duration=9999，读取上限调整为10000。
仅地图token包含坐标，防止移动中的敌人坐标被当成重复标记。kind0普通地面点、kind24快捷语音仍跳过。
XYZ必须有限且绝对值≤1,000,000；`{位置}`显示取整世界坐标，不是地图网格坐标。
环active==1才读取；收起地图时引擎active的实际行为仍需实机确认。

本地化链依据本地 Foundation 的 Localization.bind / extra_localized_text，完整99字节签名
唯一匹配当前DLL RVA17802E0；root全局3326308 → root+10 → engine+3E8。
17802FA传入uint32 key，17802FC call目标。只调用该已证实lookup，不调用会写fallback缓冲区的wrapper。
目标必须位于当前game.dll的已提交、无guard、可执行MEM_IMAGE页；调用前后与文字读取后再次核验签名/链。
最多读取1024字节且必须有NUL；拒绝非法UTF8、空名、#ID占位符；不缓存跨房名称/指针。
原生调用本身仍需实机检验，Lua pcall不等于原生崩溃隔离。

## 触发者

网络发送仍使用本机聊天对象和 `(chat,0,text)`，未发现可以代他人发送的已证实参数。
缩写来自真实roster记录：game+347CED8，8条、strideC0、名字+8、两字节缩写+89。
颜色索引来自ctx peer条目+14，按完整8字节peer匹配，0–3对应橙/蓝/粉/绿。
颜色表：FFFF9D42 / FF81ACFE / FFF68AFF / FF6ED754；依据当前chat HUD 12F2F60→1382650。
原生缩写无效但颜色槽有效时退为P1–P4；身份数据不可用则无色“队友”。不使用P2P中估计的列表序号颜色。
前缀为正文 `<c=AARRGGBB>[A2]<c=FFFFFFFF>`，可单独关闭缩写或颜色，实际发件人名字不变。
队列推入与发出前确认触发者仍在本会话，原生读取和批量交付也复核会话；切房丢弃旧事件。

## 一手参考

- [G60原生环](https://github.com/etxp/HD2-G60-Smart-Targeting/blob/main/src/g60/native_ping.lua) 与 [HD2Runtime](https://github.com/SkyeShade/HD2Runtime/blob/master/runtime/event_world.lua)：布局事实。
- [EntityComponentMap](https://github.com/Darctor/Helldivers2_RawData/blob/main/Data/settings/EntityComponentMap.json)、[EncyclopediaEntry](https://github.com/Darctor/Helldivers2_RawData/blob/main/Data/entities/EncyclopediaEntryComponentData.json)：Spottable/任务/物品身份。
- [SupportWeaponCapabilities](https://github.com/SkyeShade/HD2Runtime/blob/master/sdk/SupportWeaponCapabilities.json)、[FileDiver路径](https://github.com/xypwn/filediver/blob/master/hashes/hashes.txt)：支援装备与TCS路径交叉核实。
- [HudMarkerType](https://github.com/shalzuth/HelldiversData/blob/master/data/enums/HudMarkerType.json)：历史枚举，须配合当前DLL指令核验。

Custom UI、Better Map Markers仅用于确认图标资源职责，没有复制它们的材质或贴图。
