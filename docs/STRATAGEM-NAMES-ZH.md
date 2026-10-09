# 战备目录简体中文展示名称

这份表只为编辑页提供显示名称。名称映射按当前 `StratagemInfo` 稳定 ID 查找；它不参与行分组、名称键解析、事件身份或规则 ID。未知 ID 显示经过验证的英文 `debug_name`。

## 目录证据

2026-10-09 对运行中的游戏使用 Windows `OpenProcess(PROCESS_VM_READ | PROCESS_QUERY_INFORMATION)`、`VirtualQueryEx` 和 `ReadProcessMemory` 只读当前目录。游戏文件 `data/game/game.dll` 的 SHA-256 为 `2E2C3B7C2500646DADD5F2B4C6E0504DBB7E7896139F64CDDC0D1813C718F51E`，与 AutoChat 已支持版本一致。读取前核验了目录指针表、名称消费者与图标消费者三处既有指令签名；随后按已验证布局读取 `base+0x37CB600`、Info `+04/+10/+28/+2C/+74`，得到149个唯一稳定 ID。整个过程没有调用游戏 resolver 或其他 native 函数。

回归 fixture [`stratagem_catalog_20261009.json`](../work/standalone/tests/fixtures/stratagem_catalog_20261009.json) 只保留 stable ID、内部名、两种名称键和 call type，不包含 PID、指针、内存地址或进程数据。

## 中文名称来源

当前战备条目的中文名称参考[绝地潜兵中文 Wiki 的战略配备目录](https://helldivers.wiki.gg/zh/wiki/%E6%88%98%E7%95%A5%E9%85%8D%E5%A4%87?variant=zh-hans)和[英文 Stratagems 目录](https://helldivers.wiki.gg/wiki/Stratagems)。2026-10-09 通过只读 Cargo 查询取得英文表120条、中文表119条。用同一战略配备代码（方向序列）和分类配对后，有115对名称可唯一对应；另有2组同代码记录存在歧义，以及1条仅出现在英文表。可唯一对应的名称采用中文 Wiki 用名。

22条非投掷任务战备保留 AutoChat 已有的中文标签，见 [`task-stratagems.json`](task-stratagems.json)；该文件记录的 stable ID 和 payload 事实来自固定版本的 [RawData `generated_stratagem_settings.json`](https://github.com/Darctor/Helldivers2_RawData/blob/52056ecb5637bf8d71481a724b019a6bd3b0e9ea/Data/settings/generated_stratagem_settings.json)。旧条目、奖励变体、内部条目及 Wiki 表无法唯一配对的行，按 fixture 中逐字验证的英文 `debug_name` 手工翻译或采用其对应的已知装备名；未将这些译名描述为游戏语言资源抽取结果。两条标为未使用的内部攻击保留“未使用”提示。

`src/stratagem_names_zh.lua` 有149个当前 stable ID 映射。它作为纯 Lua 数据传入目录构造器的 `names_zh` 参数，生成独立的 `row.display_name`。`row.name` 与 `row.debug_name` 一直保留英文原值，未知新增 ID 也会回退到英文内部名，因此原有身份判断和英文搜索不受显示名称影响。
