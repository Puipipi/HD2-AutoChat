# 0.8.0 战备目录读取依据

2026-10-09。本调查仅读取仓库源码与已有离线诊断，未连接游戏、写入游戏、部署或发布。新增目录模块是独立实现，未复制第三方模组源码。

## 应读哪一版

最新测试包 `StratagemCooldown-4.11.1-test.zip` 的构建器位于 [build_manager_test.py](C:/Users/23825/Desktop/2-apex-x20/mods/stratagem-experiment/tools/build_manager_test.py:10)。其 `source()` 从稳定版 `stratagem-cooldown/tools/build_release.py` 组合源码，再添加实验工厂并修改版本号；并未替换目录读取部分。因此目录的权威当前源码仍是 [vehicle_cooldown.lua](C:/Users/23825/Desktop/2-apex-x20/mods/stratagem-cooldown/src/vehicle_cooldown.lua:135) 中的 4.10.3，不应优先采用 `work/lua-extract2` 的 4.9.6。

稳定版的 AOB 定位器见 [locate_table](C:/Users/23825/Desktop/2-apex-x20/mods/stratagem-cooldown/src/vehicle_cooldown.lua:467)，结构布局见 [OFF_ID 等常量](C:/Users/23825/Desktop/2-apex-x20/mods/stratagem-cooldown/src/vehicle_cooldown.lua:534)，指针读取见 [slot_ptr/rec_info](C:/Users/23825/Desktop/2-apex-x20/mods/stratagem-cooldown/src/vehicle_cooldown.lua:625)，扫描上限 `SCAN_IDS=255` 及逐槽保护见 [扫描](C:/Users/23825/Desktop/2-apex-x20/mods/stratagem-cooldown/src/vehicle_cooldown.lua:1231)。只复用这些读取事实，不引入其中的写内存、功能开关或冷却修改逻辑。

## 身份、名称与资源

当前 AutoChat 的版本前置是 `game.dll` SHA256 `2E2C3B7C2500646DADD5F2B4C6E0504DBB7E7896139F64CDDC0D1813C718F51E`。新的 `env.base()` 必须继续使用 [supported_game_base](C:/Users/23825/Desktop/2-apex-x20/mods/auto-chat/src/auto_chat.lua:592)，不得仅凭模块加载地址认定支持版本。下表偏移只适用于该版本；Info 本身可为四字节对齐，不能要求八字节对齐。

| 对象/偏移 | 含义 | 依据与使用方式 |
|---|---|---|
| `base+37CB600 + type*8` | Info 指针表 | 当前原生目录；额外检查 `Info+0 == type` |
| Info `+00` | 当前构建的 Type | 会随构建漂移，不作为持久化配置键 |
| Info `+04` | 32 位稳定战备 ID/hash | 每项配置存这个值，十进制字符串亦可 |
| Info `+10` | debug_name 的字符串指针 | 家族归类与未加载本地化时的保底名称 |
| Info `+28` / `+2C` | 大写/常规名称本地化键 | 两者都用于解析原生标记；仅唯一映射可返回 ID |
| Info `+50` | uses/charges | 本功能不修改它 |
| Info `+68` | float32 成功冷却定义值 | 作为展示元数据；不是玩家当前剩余冷却 |
| Info `+74` | call_in_type | `0=Throw, 1=ExactLocation, 2=LandingZoneBeacon, 3=HellpadCall` |
| Info `+98` / `+A0` | payload 资源数组/计数 | 可对应实体或装备架，不能不查关系就当作架上物品身份 |
| Info `+A8` | package 资源 ID | 资源包身份，不等于物品/战备身份 |
| Info `+B0` | 64 位 icon 图像/材质资源 hash | 用十六进制字符串保留精度；零值表示原记录没有图标 |

`+00/+04/+10/+50/+68` 直接来自稳定版读取器。`+2C/+74` 已在 AutoChat [stratagem_events.lua](C:/Users/23825/Desktop/2-apex-x20/mods/auto-chat/src/stratagem_events.lua:101) 验证。图标另有明确原生消费者证据：缓存 [task-calldown-domain.json](C:/Users/23825/Desktop/2-apex-x20/mods/auto-chat/work/standalone/dist/diagnostics/task-calldown-domain.json:47) 的 presentation pins 标出 `183A1E5: 49 8B 96 B0 00 00 00` 为 HUD slot icon，`1893650: 48 8B 97 B0 00 00 00` 为 loadout icon；后续 `1893657` 调用图像设置函数。名称消费者 `179D962: 8B 75 2C` 直接读取常规名称键。

最新模块增加三处消费者字节检查：`66D54C` 指针表、`179D962` 常规名称、`183A1E5` 图标。它读取 `+B0`，没有把稳定版原有的 `REC_READ=B0` 误认为包含图标；`B0` 字节长度实际上止于 `AF`。

当前导出表也提供 id、两种名称键、icon、call_in_type、hud_type 和 beacon_color，可用于离线交叉核对。快照版本为 1.007.100 / 2026-09-22，共 149 条有效项；原生目录观察为 150 个槽含 Type0 空槽。[固定版本 RawData](https://github.com/Darctor/Helldivers2_RawData/blob/52056ecb5637bf8d71481a724b019a6bd3b0e9ea/Data/settings/generated_stratagem_settings.json) 是字段事实的辅助依据，运行时新条目仍以原生表为准。

## 红蓝绿不是 beacon_color

稳定版 [classify](C:/Users/23825/Desktop/2-apex-x20/mods/stratagem-cooldown/src/vehicle_cooldown.lua:554) 根据原生 debug_name 归类：ORBITAL/EAGLE 为红；TEAM WEAPONS/BACKPACK/CONSUMABLES/VEHICLES 为蓝；SENTRYS/SENTRIES/EMPLACEMENTS 为绿，并优先处理地雷、Tesla、Shield Generator、Relay、Combat Walker 与部分总统奖励。未知家族保持 `other`，仍可显示和逐项设置，不自动加入颜色批量开关。

这里有一项有依据的修正：护盾生成背包（稳定 ID3843705076，当前导出 debug_name 为 `BACKPACK.  GENERATOR PACK`）的 HUDType 是 Supply、信标为 Blue。若其名称采用常见的 `BACKPACK. SHIELD GENERATOR` 写法，直接照搬稳定版“SHIELD GENERATOR 关键字优先”会误归绿。因此新目录先处理 `BACKPACK.` 前缀为蓝，再处理绿色防御结构关键字；`EMPLACEMENTS. SHIELD GENERATOR RELAY` 仍为绿。此保护针对名称写法变化，并未声称当前导出名包含 SHIELD；有专门回归测试。

`StratagemBeaconColor` 只有 None/Red/Blue/Yellow，没有 Green；不能拿信标光束颜色代替战备 UI 的类别颜色。`StratagemHUDType` 则包含 Offensive/Mission/Supply/Defensive/Special，但本次没有将其未独立验证的原生偏移加入读取器。另一个危险点是实验版将 `Info+C8` 命名为 category；飞鹰通常为 49（Rearm Type），该值不能用作红蓝绿枚举。新的模块沿用稳定版已使用的家族分类事实。[BeaconColor 枚举](https://github.com/Darctor/Helldivers2_RawData/blob/52056ecb5637bf8d71481a724b019a6bd3b0e9ea/Data/enums/StratagemBeaconColor.txt)，[HUDType 枚举](https://github.com/Darctor/Helldivers2_RawData/blob/52056ecb5637bf8d71481a724b019a6bd3b0e9ea/Data/enums/StratagemHUDType.txt)。

## 成功投掷、成功执行与去重

用户要的是成功扔出后立即警告，尤其是 500kg 和轨道凝固汽油弹。输入方向完成、选中战备、举球、当前输入槽或预备呼叫状态均不能证明已经扔出。

当前 [ping_events.lua](C:/Users/23825/Desktop/2-apex-x20/mods/auto-chat/src/ping_events.lua:683) 已限定：`kind==20 && duration==9999 && native_flags` 含 `0x2000`，才发 `source='stratagem_call', action='summon'`。注释记录当前接收端仅在解析战备管理器后设置这个 bit。其 `localization_key` 可查新目录的 upper/cased 唯一索引，不应仅比较已翻译文字。若存在同名键的不同稳定 ID，真实事件 ID 保持未知；只有其**两种原生名称键和 call_type 全部一致**时，才可用单独的 `stratagem_rule_id` 指向共同可见类型的聊天设置。不能把该设置代表 ID 填入实际 `stratagem_id`。

非投掷动作已有 [stratagem_events.lua](C:/Users/23825/Desktop/2-apex-x20/mods/auto-chat/src/stratagem_events.lua:7) 的成功记录依据：管理器 `base+347CE50`，peer record 步长 `1690`，条目 `+1C0` 步长 `30`，计数 `+7C0`。`135C5D0` 的成功分支写入条目 `start+10` 与 `activation+20`；`135C2C0` 的 start/deadline 还会因失败或共享冷却变化而更新。应继续以 activation 改变作为执行成功证据，且对跨 peer 镜像保留匿名/小队归属。

本次离线重查完整已缓存 `.text`，`135C5D0` 唯一直达 call 为 `66F9BB`，其前置寻找 Type49（Eagle Rearm）；其他调用可能走 RPC 间接分派。这证明不了所有 Throw 都在抛出球的那一帧更新 activation，也不能把 activation 的“计划抵达时间”解释为已经抵达。新生成的 [catalog-success-callers.txt](C:/Users/23825/Desktop/2-apex-x20/mods/auto-chat/work/standalone/dist/diagnostics/catalog-success-callers.txt) 记录该检查。

因此最稳妥的立即提醒路线是保留已确认的投掷标记，按唯一名称键补稳定 ID；非投掷动作保留成功记录。若另外让成功记录覆盖 Throw，需以同一稳定 ID、peer 与最近一次确认投掷事件关联去重，避免标记与记录各发送一次；无法关联时不把冷却变化当新投掷。本调查未验证“所有 Throw 的 activation 在投掷时立刻变化”，不能据此承诺零延迟覆盖。

当前两个重点目标的精确身份如下（Type 仅用于当前构建诊断）：

| 战备 | 稳定 ID | Type | upper / cased 名称键 | 图标 hash |
|---|---:|---:|---|---|
| 飞鹰 500kg | 4119049995 (`F583B70B`) | 3 | 1057738842 / 2994328991 | `F96A659EBFFDFBE4` |
| 轨道凝固汽油弹弹幕 | 2902516083 (`AD00E173`) | 106 | 3103421391 / 549159351 | `1393C79C3A21BC90` |

## 新模块接口与集成边界

[stratagem_catalog.lua](C:/Users/23825/Desktop/2-apex-x20/mods/auto-chat/src/stratagem_catalog.lua:5) 暴露 `build_stratagem_catalog(env)`，仅使用注入的 `env.base()`、`env.read(address,size)`、可选 `env.localize(key)` 和经过独立验证的 `env.resource_aliases`（unit 资源 hex → 稳定 ID）。模块不调用引擎、不加载资源、不写原生内存。

- `scan(now)` → 数量、状态；成功扫描后五秒内复用，完整快照重新检查指针表、Info、名称和消费者字节才发布。
- `list()` → 当前原生条目。每项含 `id,type,name_key,name_upper_key,name,debug_name,call_type,payload_count,group,family,icon,icon_kind,cooldown,resource_aliases,rule_id`；payload_count 来自 `+A0`，限制不超过64。
- `list_rules()` → 去除同一可见名称/调用方式的重复版本后的设置条目。代表项额外含排序后的 `variant_ids`。
- `lookup(stable_id)` 接受数值或十进制字符串。
- `resolve_name_key(key)` 只返回唯一的常规或大写名称键映射。
- `resolve_resource(hex)` 使用 38 条已验证的默认实体别名，也接受显式注入的已验证补充项。模块没有将所有 payload/package/hash 不加检查地当作世界实体别名。
- `resolve_rule_name_key(key)` 在所有该键候选都属于同一个精确双名称键+call_type 身份时返回设置代表项；任意单键碰撞不合并。
- `resolve_rule_resource(hex)` 除唯一别名外，对7个已验证共享资源候选图检查**完整候选集**。所有候选都存在、且都属于一个共同可见身份时才返回设置代表项；缺失候选或不同身份均不解析。
- `state.ready/status/generation` 表示最新快照是否可用。失败或不支持版本清空活动索引，避免旧身份参与消息发送。

目录按稳定版方式扫描 1..255，逐槽验证 `Info.type==slot`、稳定 ID 非零、call type 范围与名称结构；发现新 ID 自动出现在列表，未知家族进“其他”。这一界限足够覆盖当前 149 项，但不是无限扫描；将来目录超过 255 或 DLL 指纹/布局变化，需要更新验证，不能承诺未知二进制可自动适配。当前149项原生目录得到135种可见设置身份；14对同名/同调用方式的版本共享设置。两种名称键任一为零时保持独立，避免将未知名称误合并。

代表项按固定顺序选择：优先非 `PRESIDENT REWARDS.` 且非教学条目，其次有原生图标，最后稳定 ID 较小者。所有同组原生行的 `rule_id` 指向它，颜色/家族沿用代表项；例如无图标的奖励补给条目会加入正常补给的蓝色组。GUI 使用 `list_rules()`，并注明同名版本共享设置。用户配置保存代表项稳定 ID，可跨 Type 重排保留；这仅是设置身份，不声称实际调用的是代表版本。

逐项冷却应是聊天节流配置，和游戏的 `Info+68` 分开。建议 `{enabled,text,cooldown}` 以设置代表稳定 ID 持久化：`cooldown=nil` 可继承，`cooldown=0` 表示该项绕过全局聊天冷却，非零则使用自己的上次发送时间。颜色批量按钮修改可见设置目录中该颜色各项的 enabled，不改游戏。事件同时保留两个独立字段：有唯一证据才填 `stratagem_id`；设置解析成功时填 `stratagem_rule_id`。正常/奖励变体无法区分时也必须执行共同设置的禁用、自定义文本与冷却，不绕回公共规则。

## 图标资源种类与安全绘制

`icon_kind='material'` 依据仓库 [StratagemInfo schema](C:/Users/23825/Desktop/2-apex-x20/work/refmod/strike-research/components_StratagemInfo.json:30) 的 icon `[material]` 标注，当前原生 HUD 的 `+B0` 消费者，以及 HUDPlus 将图标材质解析为纹理的实际读取方式；它不是“可直接喂给任意纹理槽的 texture ID”。每次实际绘制必须再以引擎 `can_get('material', IdString64.from_hex(row.icon))` 验证当前资源种类和加载状态，不凭 schema 直接提交。

最小可用路径是：有效 GUI 已建立，`Application.can_get('material', iconId)` 返回 true，且 `Gui.bitmap_uv` 可用时，调用 `Gui.bitmap_uv(gui, iconId, Vector2(0,0), Vector2(1,1), position, size, color)`。传入的是已经加载的原生材质资源 ID；不将 `row.icon` 当作纹理，不需要 HD2_HUD_Plus 安装，不新增材质资产。资源尚未加载、原记录 icon 为零或 API 缺失时继续显示名称/占位，稍后重试。

HUDPlus 的另一条完整路径是 **材质 -> 纹理 -> 自有图标材质**，不能只截取末尾 set_texture 调用。其 [material_texture](C:/Users/23825/Desktop/2-apex-x20/work/lua/HD2_HUD_Plus_0.1.12_15298_0.1.12_2026-09-24T11-49Z_JxBvkNTbx__p.patch_0.lua:2156) 在资源索引按 material 类型 `EAC0B497876ADEDF` 找到材质数据，再从 payload+140 读出纹理。其 [bind_texture](C:/Users/23825/Desktop/2-apex-x20/work/lua/HD2_HUD_Plus_0.1.12_15298_0.1.12_2026-09-24T11-49Z_JxBvkNTbx__p.patch_0.lua:8559) 通过 `Gui.material` 得到当前 GUI 的实例，将真正的 texture ID 绑定到 `3aa8b87e00000000` 槽，然后通过 [Gui.bitmap_uv](C:/Users/23825/Desktop/2-apex-x20/work/lua/HD2_HUD_Plus_0.1.12_15298_0.1.12_2026-09-24T11-49Z_JxBvkNTbx__p.patch_0.lua:9370) 绘制；其最终用的是自身打包的 `mods/hd2_hud/native_icon_atlas` 材质（[配置](C:/Users/23825/Desktop/2-apex-x20/work/lua/HD2_HUD_Plus_0.1.12_15298_0.1.12_2026-09-24T11-49Z_JxBvkNTbx__p.patch_0.lua:10043)），不应将该私有资源名直接加入 AutoChat。

这条自定义纹理路径若未来需要，必须分别确认 material 和 texture 都 can_get，使用已验证的图标材质，并在 GUI 重建后重新获得实例、重新绑定。当前选择加载检查后的原生材质直接绘制。API 用法得到仓库源码支持，实际显示效果仍未在本次调查中连接游戏验证。

## 已验证装备别名与明确歧义

新增 [stratagem-resource-aliases.json](C:/Users/23825/Desktop/2-apex-x20/mods/auto-chat/docs/stratagem-resource-aliases.json) 保存 38 个唯一别名、7 个多 ID 候选及3个没有足够连接证据的资源。推导方式是原生导出 StratagemInfo 的显式 payload 资源，或该 payload 对应的 HellpodRack 的 `payloads[].item`，再和当前 EntityComponentMap 的资源身份交叉确认；不是仅比较名称。模块默认别名表和 JSON 有精确一致性测试。

| 资源/装备 | 精确连接 | 稳定战备 ID |
|---|---|---:|
| M-103 补给车 `9B2140378640432E` | 该车辆正是战备显式 payload | 2636699686 |
| LAS-98 装备架 `FDE262593307CA2F` | 战备显式 payload | 2822568285 |
| LAS-98 手持 `D54B9505C0F72873` | 上述 rack 的显式 item | 2822568285 |
| 护盾生成背包装备架 `F88D61A8FE1E0766` | 战备显式 payload | 3843705076 |
| 护盾生成背包 `12C8D71AC3897A5C` | 上述 rack 的显式 item | 3843705076 |
| 防弹盾装备架 `3A50B58B0553056A` / 物品 `967ED15E0BAE363B` | payload 与 rack.item | 3353508219 |
| 定向护盾装备架 `09183066C4EBCE28` / 物品 `A4E796F84801B40A` | payload 与 rack.item | 272480476 |

补给架 `5052EC6A928CCF1A` 与补给箱 `A94913CA014F7579` 同时属于正常补给 `867876502` 和总统奖励 `1295431756`（`PRESIDENT REWARDS. AMMO CACHE`，不是教学补给）。它们的 upper/cased 两个名称键也都相同，分别为1263463686/1673875834，call_type 同为0。因此无论名称键还是该资源本身，都不能证明实际是哪一个原生 ID。**不存在可单独区分正常补给的专属名称键**；先前的相反表述已修正。

这两项属于共同可见类型“重新补给”，GUI 只显示正常补给代表867876502的一项设置。`resolve_name_key` 和 `resolve_resource` 仍返回未知，`resolve_rule_name_key` 和 `resolve_rule_resource` 则返回代表设置，保证两种来源都遵循用户对重新补给的禁用、文本和冷却设置，同时不虚构调用来源。喷气背包也有同样的正常/奖励配对：1753436707 与3316399568共享2204198870/2872120750/call_type0，代表为正常背包1753436707。

另一个已支持的补给箱 `49119612EB284A48` 没有当前 rack 显式连接，不能凭名称猜测；若原生标记本地化键能解析到共同可见身份，可使用该设置，否则保持未知。事实表的7个共享资源候选集只有在所有候选完整存在且属于一个共同身份时才启用规则解析，不会删掉不方便的候选来制造唯一性。

部分武器资源也被多种奖励/任务战备共同使用，例如 MG-43、反器材步枪、喷火器、EAT。EAT 的完整两个候选可属于同一个双键+调用身份，因此可解析共同设置；包含不同名称键的混合武器奖励缓存则保持未知，即使其中另两个候选恰好同名。JSON 保留所有候选和14个可见身份合并组。500kg 和轨道凝固汽油弹的调用以名称键定位；本次没有声称已经验证其爆炸特效/弹药实体就是可标记的装备别名。

上述 Rack 数据固定在 [当前 HellpodRackComponentData](https://github.com/Darctor/Helldivers2_RawData/blob/52056ecb5637bf8d71481a724b019a6bd3b0e9ea/Data/entities/HellpodRackComponentData.json)，缓存为 `work/standalone/dist/diagnostics/catalog-HellpodRackComponentData.json`。实体身份以已有 `component-map.json` 同版本缓存核对。只分发派生连接事实，不分发第三方 Lua 实现或图标贴图。

## 离线验证

`python -m unittest discover -s work/standalone/tests -p test_stratagem_catalog.py -v`：21 项通过，覆盖新条目发现、Type 重排仍保留稳定身份、原生中文名称及超过 2^53 的图标 hash 精度、真实 ID 与可见设置身份分离、补给/喷气背包奖励变体、单键碰撞和不同call_type不合并、零名称键不合并、完整资源候选集、代表项选择顺序、颜色归属、payload_count范围、别名与事实表一致性、版本/扫描一致性保护和节流。

另外将当前149个实际导出条目全部重放到离线稀疏内存：得到135个可见设置身份，补给/喷气背包正确解析设置代表而实际ID保持未知；MG-43与混合武器缓存的共享资源仍不误解析。未连接游戏，未验证实际投掷时序与 GUI 图标呈现。

第三方边界遵循 [StratagemCooldown THIRD_PARTY_NOTICES](C:/Users/23825/Desktop/2-apex-x20/mods/stratagem-cooldown/THIRD_PARTY_NOTICES.md:7)：其 Tank Cooldown 原参考源码没有新增许可授予，不应直接拷贝分发。本模块只重新实现已记录的偏移、消费者字节、身份和分类事实；没有将研究缓存或游戏图标贴图加入发布包。
