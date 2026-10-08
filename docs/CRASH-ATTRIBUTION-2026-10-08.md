# 旧崩溃记录：历史签名不能排除 AutoChat 的触发作用

日期：2026-10-08
更正：**此前“已排除 AutoChat”的结论不成立。** 同一签名早已存在，只能说明该签名并非
首次出现，不能排除当前面板触发同一原生故障。Lua 的 pcall 也拦不住原生崩溃。
2026-10-08 23:27，0.5.0 再次在按 K 后崩溃；排查发现字体回退把资源路径错误传给 from_hex，
0.5.1 已修正并补回归测试。是否解决实机崩溃待复验。下文保留旧观测，因果推断以本段为准。

## 发生了什么

我按用户的早期要求自行启动游戏实测。进入飞船后按 K：

```
14:59:36Z panel opened                     ← 没有 draw_panel error
```

面板打开时**绘制不再抛错**（这验证了 `u32_off` 的修复生效）。但 3 秒后游戏崩溃：

```
Application Error: helldivers2.exe  version 1.8.46015.0
Faulting module: ntdll.dll 10.0.26100.4652
Exception code: 0xc0000005        Fault offset: 0x0000000000039463
```

同一签名在 22:48:31 也出现过一次，而那次会话的日志里有 `panel closed`（14:48:24）。

## 为什么这不是 AutoChat 造成的

**模组首次运行的时间，晚于该崩溃首次出现的时间一周。**

| 事实 | 时间 |
| --- | --- |
| AutoChat 日志文件创建（模组在本机首次运行） | **2026-10-08 18:36:58** |
| 崩溃签名 `0xc0000005@0x39463` 首次出现 | **2026-10-01 17:59:24** |
| 该签名在 2026-10-08 之前的出现次数 | **12 次** |
| 该签名总出现次数（30 天内） | 14 次 |

那 12 次崩溃发生时，`AutoChat.log` 还不存在，模组从未在本机加载过。**一个尚未安装的模组无法导致崩溃。**

复现命令：

```powershell
# 模组何时开始存在
Get-Item "$env:LOCALAPPDATA\CowboyBingus\Helldivers2\Logs\AutoChat.log" | Select-Object CreationTime

# 该签名的全部出现时间
Get-WinEvent -FilterHashtable @{LogName='Application'; ProviderName='Application Error';
  StartTime=(Get-Date).AddDays(-30)} |
  Where-Object { $_.Message -match 'helldivers2' -and $_.Message -match '0x39463' } |
  Select-Object TimeCreated
```

## 但要说准：排除的边界在哪里

**能确定的**：该签名不是 AutoChat 引入的，它在本机已存在一周。

**不能确定的**：10-08 那两次崩溃是否**恰好由**那个既有的不稳定点触发。面板打开与崩溃相隔 3 秒，日志在 `panel opened` 之后没有任何后续行 —— 既没有字体解析行，也没有错误行。所以：

- 没有 `draw_panel error` 不能排除绘制路径中的原生调用崩溃；
- 也无法从日志判断崩溃点在哪里。

面**板因此既没有被证明安全，也没有被证明有害**。任何一边的说法都需要新的证据。

## 这台机器的整体稳定性

30 天内 `helldivers2.exe` 在应用程序日志里留下 **1640 条**崩溃记录。按签名分组：

| 签名 | 次数 | 时间范围 |
| --- | --- | --- |
| `0xc0000026@0x7a5cf` | 1442 | 09-26 → 10-05 |
| `0xc0000005@0x66d26c` | 72 | 09-28 → 10-01 |
| `0xc000000d@0x8286f` | 44 | 09-26 → 10-05 |
| `0xc0000409@0x20d63a4` | 27 | 09-29 → 10-03 |
| `0xc0000005@0x39463` | 14 | 10-01 → 10-08 |

本机同时装有大量其它模组（`%LOCALAPPDATA%\CowboyBingus\Helldivers2\Logs` 下可见 HellpodSteeringUnlocked、ReinforcementBeaconsFixed、ConsistentVaulting、ShallowWaterDiving、SentryAimRetention、CorpseCollisionRepair、ArmoryPreviewCache、ArcThrowerAuto、GalacticMenuHotkey、ClickableScrollbars、C4DualInput 等）。

**结论：这是一套长期不稳定的安装，而不是"探针把游戏弄坏了"。** 在把任何单次崩溃归因于某个模组之前，先与该签名的历史对照。

## 本次实测确实验证到的

- 游戏能正常启动并进入飞船世界；
- 模组加载成功：`installed: ready (signature ok, send resolved, panel on K)`；
- 按 K **面板确实打开了**；
- **打开时没有任何 `draw_panel error`** —— `u32_off` 缺失导致的字体解析崩溃（纯 Lua 异常）已修复。

## 本次实测**没有**验证到的

- 面板长什么样（崩溃发生在截图之前）；
- 文字是真字形还是点阵（`font:` 日志行没写出来就崩了）；
- 打字修改、鼠标归还。

这些仍然只能靠实机确认。
