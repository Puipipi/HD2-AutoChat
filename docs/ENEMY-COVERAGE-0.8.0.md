# 0.8.0 敌人覆盖与飞行分类核对

核对日期：2026-10-09。此报告核对的是升级前 `src/ping_events.lua` 的 79 条敌人资源，以及当前可公开取得的游戏配置导出。没有读写游戏进程，也没有增加任何内存偏移。

## 数据版本与证据等级

本次查询时 [Darctor main 的固定提交](https://github.com/Darctor/Helldivers2_RawData/commit/52056ecb5637bf8d71481a724b019a6bd3b0e9ea) 为 `52056ecb5637bf8d71481a724b019a6bd3b0e9ea`，日期 2026-09-22；本文使用的 Component 和 EntityComponentMap 元数据均为 `game_version=1.007.100`、`patch_date=2026-09-22`。路径名称另使用 [FileDiver 2026-10-09 提交](https://github.com/xypwn/filediver/commit/9f92623133cde32b1167e13f05ce6c4825805ccf)。游戏配置与资源路径表的日期应分别记录。

这些是社区对游戏自身配置/类型库的直接导出，不是 Arrowhead 发布的官方源码或官方完整敌人名录。RawData 自己说明仅导出部分数据，可能含未上线资源，名称表也可能不完整或有误。因此可以回答“游戏内部用什么体型枚举”和“这批导出包含什么”，不能据此承诺未来更新后所有实战敌人必然已经覆盖。[RawData 数据说明](https://github.com/Darctor/Helldivers2_RawData/blob/52056ecb5637bf8d71481a724b019a6bd3b0e9ea/README.md)

当前插件的 Steam build/DLL 指纹约束仍以现有源码为准。公开 JSON 只有版本和补丁日期，不包含能独立证明 `Steam build25480438` 与 DLL SHA256 的证据；本报告没有重新验证这层映射。更新数据目录不能代替 DLL 布局验证。

## 体型是不是游戏本身的分类

是游戏内部 `HealthComponentData.unit_size` / `UnitSize` 的分类；中文“小型 / 中型 / 大型 / 巨型”是插件显示名称。

| 值 | 游戏内部枚举 | 插件名称 |
| --- | --- | --- |
| 0 | UnitSize_Small | 小型敌人 |
| 1 | UnitSize_Medium | 中型敌人 |
| 2 | UnitSize_Large | 大型敌人 |
| 3 | UnitSize_Massive | 巨型敌人 |
| 4 | UnitSize_Num | 数量哨兵，不是第五种体型 |

顺序由当前 [UnitSize 导出](https://raw.githubusercontent.com/Darctor/Helldivers2_RawData/52056ecb5637bf8d71481a724b019a6bd3b0e9ea/Data/enums/UnitSize.txt) 和历史 [HelldiversData 枚举](https://raw.githubusercontent.com/shalzuth/HelldiversData/0d18368a707a048d153aec7918f6c12127652283/data/enums/UnitSize.json) 相互印证；具体敌人的值来自当前 [HealthComponentData](https://raw.githubusercontent.com/Darctor/Helldivers2_RawData/52056ecb5637bf8d71481a724b019a6bd3b0e9ea/Data/entities/HealthComponentData.json)。体型不是装甲等级或威胁等级：例如潜行虫是 Large、巢穴指挥官也是 Large，护理喷吐虫为 Medium。设置说明应避免把 Large 解释为“重甲”。

## 升级前是否已覆盖全部敌人

没有。79 条均与当前 Health 体型一致，但是没有 Small，而且还漏掉部分 Medium / Large 变体。统计单位是资源 ID，包含 MK/生成/阵营变体，不是玩家口中的独立物种数。

核对规则：先读取 [EntityComponentMap](https://raw.githubusercontent.com/Darctor/Helldivers2_RawData/52056ecb5637bf8d71481a724b019a6bd3b0e9ea/Data/settings/EntityComponentMap.json)，再交叉 [FactionComponentData](https://raw.githubusercontent.com/Darctor/Helldivers2_RawData/52056ecb5637bf8d71481a724b019a6bd3b0e9ea/Data/entities/FactionComponentData.json)、Health 与 [AiEnemyComponentData](https://raw.githubusercontent.com/Darctor/Helldivers2_RawData/52056ecb5637bf8d71481a724b019a6bd3b0e9ea/Data/entities/AiEnemyComponentData.json)。本报告把 `Bugs / Cyborg / Illuminate` 作为已知敌对阵营，并选择带有 `AiEnemy`、`EnemyPackage` 或 `VehicleShuttle` 的资源；静态敌方建筑继续属于任务建筑目录。

| 体型 | 升级前静态目录 | 敌对 AiEnemy 资源 | 加上首领/运输舰等例外 | 其中有 Spottable |
| --- | ---: | ---: | ---: | ---: |
| Small | 0 | 47 | 47 | 45 |
| Medium | 41 | 46 | 46 | 46 |
| Large | 33 | 40 | 41 | 40 |
| Massive | 5 | 5 | 11 | 11 |
| 合计 | 79 | 138 | 145 | 142 |

全部 79 个旧 ID 都在上述 145 条里，体型值没有不一致。其中只有 78 条带有 Spottable，所以与 142 条可标记候选比较，旧目录缺 64 条：Small 45、Medium 5、Large 8、Massive 6。Spottable 代表配置允许标记，并不保证某任务会生成、某时刻仍存活，或当前原生标记环一定交付该实体。

最容易影响用户理解的遗漏包括：小型的 Scavenger / Hunter / Pouncer / Trooper / Raider / Voteless 系列、Shrieker 及 gloom 资源；Medium 的 Gazer / Obtruder；Large 的 Reinforced Scout Strider / Predator Stalker；以及不带 AiEnemy 的 Hivelord、Leviathan、Stingray、Dropship 与 Warp Ship。完整 ID、体型、阵营、可标记性和本地化 key 见 [enemy-catalog.json](enemy-catalog.json)。

AiEnemy 不能单独证明敌对：当前组件表有 158 个 AiEnemy，其中 20 个是 SuperEarth 的平民和 SEAF，全部没有 Spottable。本次生成器明确排除它们。把 AiEnemy 全部自动纳入会造成友军误分类。[AiEnemy 表](https://raw.githubusercontent.com/Darctor/Helldivers2_RawData/52056ecb5637bf8d71481a724b019a6bd3b0e9ea/Data/entities/AiEnemyComponentData.json)、[Faction 表](https://raw.githubusercontent.com/Darctor/Helldivers2_RawData/52056ecb5637bf8d71481a724b019a6bd3b0e9ea/Data/entities/FactionComponentData.json)

另有 3 条敌对 AiEnemy 没有 Spottable，目录保留审计事实，但不能声称普通敌人标记会触发它们：

| ID | 导出名称 | 备注 |
| --- | --- | --- |
| 304C3124208291E9 | Illuminate Drone | Small，有 Hover，无本地化名称 key |
| 684284354532CC0E | N/A | Small，无可靠名称/路径/key |
| 5D142C3A73EBC634 | Barrager Tank Ballistic Missile | Large；旧目录已收录；名称表与实际资源路径职责需谨慎区分 |

最后一条的 [FileDiver 路径](https://raw.githubusercontent.com/xypwn/filediver/9f92623133cde32b1167e13f05ce6c4825805ccf/hashes/hashes.txt) 是 `content/fac_cyborgs/turrets/cyborg_tank_turret_rocketlauncher/cyborg_tank_turret_rocketlauncher`，因此不能只按手工名称断言它是一个可标记的飞行导弹。

## 飞行是独立维度

飞行优先路由到独立设置、文本与冷却，仍保留本身的 UnitSize 作为审计事实。比如尖啸虫是 Small、飞行监督者是 Medium、枪艇是 Large、Dragonroach 是 Massive；不能根据体型或名称含不含“飞行”决定分类。

当前组件证据有三类：`HoverComponentData` / `AirborneNavigationComponentData`；枪艇与攻击舰的 `BoidsComponentData` 加 `ThrusterGroupComponentData` 或 `VehicleCrashComponentData`；运输舰的 `VehicleShuttleComponentData`。先确认敌对阵营与敌人/运输实体身份，避免把友方鹈鹕、装备、残骸或单纯带 Boids 的场景对象当敌人。这里表示“配置具备飞行移动”，不是目标此刻离地高度。[EntityComponentMap](https://raw.githubusercontent.com/Darctor/Helldivers2_RawData/52056ecb5637bf8d71481a724b019a6bd3b0e9ea/Data/settings/EntityComponentMap.json)

| 资源 ID | 名称 / 已核实路径身份 | 原体型 | 飞行证据 |
| --- | --- | --- | --- |
| 64090088502435DD | Shrieker | Small | Hover |
| F0B26FA9258128D3 | cha_shrieker_gloom；名称 key 与 Shrieker 相同 | Small | Hover |
| 604A794EC45BB820 | Elevated Overseer | Medium | Hover |
| AC60E78435098C9D | Watcher | Medium | Hover |
| 34DFD23365472E9E | Obtruder | Medium | Hover |
| 282EB766C1FFA6A1 | Gunship | Large | Boids + Thruster + Crash |
| 19E18B46EC55D94A | Stingray / illuminate_attack_ship | Large | Boids + Crash |
| 960B48A421A3FAAA | Dragonroach / cha_dragon | Massive | Hover + AirborneNavigation |
| 98152772A72F7838 | Dropship | Massive | Boids + Thruster + Shuttle + Crash |
| DB90077E76FAA025 | cyborg_dropship；名称 key 与 Dropship 相同 | Massive | Boids + Thruster + Shuttle + Crash |
| 74E2285C01DA4F71 | Warp Ship / illuminate_dropship | Massive | Boids + Thruster + Shuttle |
| 2AD2E055DAD21F6E | Warp Ship Invasion | Massive | Shuttle |

此外 Illuminate Drone 带 Hover，但是不可标记，合计是 13 条飞行资源、12 条可标记飞行候选。此表中的路径均通过 MurmurHash64A(seed=0) 计算并与实际实体 ID 相等，未按近似名字猜测。[资源路径表](https://raw.githubusercontent.com/xypwn/filediver/9f92623133cde32b1167e13f05ce6c4825805ccf/hashes/hashes.txt)、[本地化 key 表](https://raw.githubusercontent.com/Darctor/Helldivers2_RawData/52056ecb5637bf8d71481a724b019a6bd3b0e9ea/Data/entities/EncyclopediaEntryComponentData.json)

暂时跳跃、背负喷气装置不等于上述持续飞行能力。Jet Brigade 的地面单位不会仅因为名称而进入飞行分类。另一方面，Leviathan 虽然是 Massive 且没有 AiEnemy，当前没有上述飞行组件证据，不能凭体型或载具名称把它标为飞行。

## 新敌人如何自动补入

[generate_enemy_catalog.py](../tools/generate_enemy_catalog.py) 已提供按组件交集生成完整事实目录的可复现流程。默认使用固定提交，原始大文件只缓存到系统临时目录，仓库只保存约 78 KB 的 145 条摘要；没有复制模型、贴图或整份游戏配置。

```powershell
python tools/generate_enemy_catalog.py
# 重新下载同一固定版本，验证可复现性：
python tools/generate_enemy_catalog.py --refresh
# 指向已核实的新数据提交；SHA 必须是完整的 40 位值：
python tools/generate_enemy_catalog.py --revision <已核实的RawData提交SHA> --hashes-revision <已核实的FileDiver提交SHA>
```

生成器会检查五张数据表的版本/补丁日期一致、AiEnemy 表与组件成员资格一致、UnitSize 枚举未改变，记录每份输入的 SHA256，并保留未知名称/未知路径为 N/A/null。当前 120/145 条找到精确资源路径；其余 25 条不能编造路径。名称优先使用运行时本地化 key；导出 `name/name_zh` 来自手工名称表，只适合有来源的回退。

这实现的是“新配置出现后可自动生成目录”。它本身没有启动联网后台任务，也没有修改运行时、部署、发版或放宽 DLL 指纹检查。要实现更新后的全自动接入，运行时仍需经过当前版本已证实的组件读取链取得阵营、Health.unit_size 与移动组件，并在未知目标出现时按证据分类；如果只有未知资源 ID 与通用“敌人”文本，无法可靠判断体型或飞行，应保持未分类并记录诊断，不能默认 Medium 或凭名称猜测。

因此可以保证当前公开导出中、上述明确定义范围内的 145 条资源都进入了事实目录。不能保证未知组件架构的新敌人、未公开的新版本，或现有 DLL 不兼容更新后仍无须验证就自动工作。未来新增阵营、体型枚举或飞行组件需要更新分类规则；现有架构下新增资源则无需人工逐条补 ID。

## 本次验证

- 读取公开 GitHub API，确认 RawData main 的提交与版本；FileDiver 路径另固定到查询当日提交。
- 本地已缓存 EntityComponentMap、EncyclopediaEntry 的 Git blob SHA1 与该 RawData 提交的 Git tree 一致；Health、Faction、AiEnemy 从固定提交下载。
- 生成器输出 145 条唯一 ID、138 条敌对 AiEnemy、7 条例外、142 条 Spottable、13 条飞行、12 条可标记飞行，20 条非敌对 AiEnemy 被排除。
- 与升级前 79 条目录逐项比较：全部 ID 都存在，体型值全部一致；其中 1 条缺少 Spottable。
- 资源路径通过哈希等值匹配，当前解析出 120 条；对所有已解析路径可重新计算并核验资源 ID。
- 实际执行语法解析、唯一 ID 检查、120 条路径重新哈希、敌对阵营过滤、12 条可标记飞行计数与确定性重生成；混合版本和新增未知体型枚举均按预期拒绝。目录 SHA256 为 `c3c93edc4ebb019f24c674dd6129f3ed59e1094e426ca49d19c9837f803c88fc`。
- 该研究未执行实机标记验收；是否送入当前标记环、原生名称解析及设置路由须在实现侧另行验证。
