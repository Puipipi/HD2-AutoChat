# AutoChat 0.7.2 验证 — 2026-10-09

用户确认测试的是本人的重新补给、补给车、LAS-98激光大炮标记。0.7.1有两处明确过滤：
`ping_events.target`拒绝creator等于本机peer；`chat_automation.creator_present`的无姓名信息后备成员检查只遍历远端玩家。
原有测试还将本人地图标记断言为应当忽略，因此此前离线通过不能证明满足本人的测试方式。

本次移除读取层本人过滤，并让成员后备检查包含本机，仍要求完整ID属于当前会话。
继续使用原生标记归属、会话复核、每人间隔、主机/客机和单人发送策略。

## 资源依据

以下实体在2026-09-22导出的EntityComponentMap中存在SpottableComponentData，资源路径用FileDiver路径表及本仓库Murmur64计算核对：

| 资源 | 路径 | 战备提示兜底名 |
| --- | --- | --- |
| 5052EC6A928CCF1A | content/fac_helldivers/hellpod/ammo_rack/ammo_rack | 重新补给 |
| A94913CA014F7579 | content/fac_helldivers/hellpod/ammo_rack/supply_box | 重新补给箱 |
| 49119612EB284A48 | content/fac_helldivers/hellpod/ammo_rack/ammo_box | 重新补给箱 |
| 9B2140378640432E | content/fac_helldivers/vehicles/frv_supply/frv_supply | M-103 补给车 |

这里按资源身份分类，不假定所有载具kind都是补给车。游戏名称可读时仍优先采用游戏名。
其他普通弹药、针剂、手雷和样本19种旧资源继续排除。

来源：[EntityComponentMap](https://raw.githubusercontent.com/Darctor/Helldivers2_RawData/main/Data/settings/EntityComponentMap.json)、
[FileDiver hashes](https://raw.githubusercontent.com/xypwn/filediver/master/hashes/hashes.txt)。

## 验证

- 先增加本人激光大炮/地图读取、无姓名信息的本人消息发送测试，旧代码分别失败；修复后通过。
- 再增加补给舱、两种补给箱、补给车分类测试，四种资源旧表均失败；补齐后通过。
- 读取器与真实消息策略控制器组合测试覆盖单人主机的激光大炮、补给舱、补给车、地图标记：读取→入队→发送，并验证重复轮询不重复发送。
- 本人标记与本机定时任务共用同一消息间隔；关闭无人房发送仍拦截，离队和切房保护测试保留。
- 完整测试命令：`python -B -m unittest discover -s work/standalone/tests -v`。
  **242项通过，26.695秒，0失败**；日志 `work/deploy/tests-0.7.2.txt`。
- LuaJIT编译、片段一致性及构建门禁通过；ZIP CRC与归档规范化源码逐字节相等。

## 安装与范围

主包 `dist/AutoChat-0.7.2.zip`：74004字节，SHA256
`105C092BDAEDB598D179F294E010FFFDC0D9FEB43E7E25F454CF303B2B6F37F1`。
游戏槽313、管理器现有GUID库及ZIP payload一致：212560字节，SHA256
`A6E2BAB4D9DEEA8B95B8CB1EAF31085964C18B64827FB277842FEA30A70180F0`。
保留0.7.1 payload和管理器库备份。用户设置/任务文件hash不变；SmoothBoot槽336不变；未重新安装已移除的示例。
机器结果 `work/deploy/verification-0.7.2.json`。

本次游戏未运行，未取得修复后的实机记录。启动/重启后确认0.7.2，在关闭设置面板后重新标记。
总开关、玩家标记、战备提示/地图标记必须打开；仅主机策略要求当前为主机，单人测试要求允许无人房发送。
首次读取已有标记只建立基线，不补发；正常消息间隔仍有效。不能将这些离线测试表述为实机验收通过。
