# 实机取证 2026-10-08

机位：Steam build 25480438 / EXE 1.8.46015.0，`game.dll` SHA-256
`2E2C3B7C2500646DADD5F2B4C6E0504DBB7E7896139F64CDDC0D1813C718F51E`。

时间戳全部是 UTC，本地时间 = UTC+8。日志里的 `12:xx:xxZ` = 本地 20:xx。

> **一句话结论：发送通路已在实机跑通并由游戏自身证据确认；"别的玩家是否收到"没有验证，
> 因为整场会话里本机始终只有一名玩家。**

---

## 1. 部署方式与回退

槽位 336（`data\9ba626afa44a3aa3.patch_336`）。装之前 `9ba626afa44a3aa3.patch_*`
是 0..335，**没有空位**。

回退：

```powershell
python -B work/standalone/deploy.py --rollback --slot 336
```

脚本先核对哈希，确认该槽位确实是本模组写的才动手。**实测回退后层文件数 = 707，
与安装前记录的 707 完全一致**，`game.dll` 哈希不变。

---

## 2. 加载器与稳定性

```text
mods/codex/auto_chat: loaded
Startup finished: 62 loaded, 0 failed        <- 装之前是 61 loaded, 0 failed
```

多次会话累计约 40 万帧、230 万次读取，**errors = 0**，**没有产生任何新的崩溃转储**，
游戏均以 `CloseMainWindow` 正常退出（3–6 秒）。

实机验证到的签名状态：

```text
signature : match
send ready: true
```

`send ready: true` 的含义要说清楚：它证明把一个**已通过签名校验**的绝对地址成功
转成了可调用的函数指针。它不证明调用就一定能发出去——那要另外的证据，见 §3。

---

## 3. 发送通路：游戏自己确认接受了消息

强制发送一条（绕过"房间里要有别人"的守卫，纯粹做通路验证），游戏自身的聊天计数：

```text
trigger: sending 10 bytes: AUTOTEST-2   [FORCED ...]
sent 10 bytes to 0 other player(s); history 0/0 -> 0/1
ring: 1 lines held
```

随后连发三条，计数稳定递增：

```text
sent 8 bytes  to 0 other player(s); history 0/1 -> 0/2
sent 8 bytes  to 0 other player(s); history 0/2 -> 0/3
sent 10 bytes to 0 other player(s); history 0/3 -> 0/4
```

**`history` 是游戏自己维护的字段。** 它从 `0/0` 变到 `0/4`，是游戏在说"这条我收下了"，
不是模组自称成功。如果那次调用打偏了，这个计数不会动。

发送文本在聊天对象里的落点（`find` 命令，逐字节精确匹配）：

| 消息 | 命中位置 |
| --- | --- |
| `HELLO-FROM-AUTOCHAT` | `chat+0xBA0` |
| `LINE-ONE` | `chat+0xDC8` |
| `LINE-TWO` | `chat+0xFF0` |
| `LINE-THREE` | `chat+0x1218` |

相邻间隔全部是 **0x228**，与从游戏自身历史访问器读出的环形槽步长一致
（该访问器用 `and edx, 0x3f` 掩码索引、`imul rbp, rax, 0x228` 定位槽，
所以是 64 槽 × 552 字节）。**文本落在 entry+0x208**（0xDC8 − 0xBA0 = 0x228）。

调用目标经核对是 `game.dll+0x1097560`——就是 32 字节签名校验通过的那一个。

### 3.1 结构证明：我们调的就是聊天框自己调的那个函数

这是"不是本地自绘/回显"这条要求的机械形式。用内存转储反汇编**聊天框自己的调用点**
（`game.dll+0x186025d`），把那条 `call rel32` 解析出来：

```text
   mov rcx, qword ptr [rip + 0x1c1cc8c]
   lea r8,  [rdi + 0x16d4]          ; 已输入文本的缓冲区
   add rcx, 0xc418                  ; 聊天对象 = 上下文 + 0xC418
   call 0xffffffffff837303          ; → 解析后 = game.dll+0x1097560

chat box calls : game.dll+0x1097560
AutoChat calls : game.dll+0x1097560
same function  : True
```

也就是说：聊天框按回车时，用 `rcx = 聊天对象(ctx+0xC418)`、`r8 = 文本缓冲区`
去调 `game.dll+0x1097560`；AutoChat 传的是**同一个对象、同一个偏移、同一个函数**。
所以消息走的是"你手打一条"所走的同一条路径，不是只在本机显示的东西。

这条检查是可重复执行的：

```powershell
python -B work/standalone/tools/verify_send_site.py \
    --dump <section0.bin> --headers <headers.bin>
```

（需要**内存转储**：安装目录里那个 `game.dll` 是加壳的，扫它只会得到"签名找不到"。）

`tests/test_signature_provenance.py` 里另有两条断言把模组的 `M.SEND_RVA` 与
`M.CHAT_OBJECT` 钉死在上面这两个数字上，防止以后改动让两边悄悄错开。

**这条证明的是"走的是同一条发送路径"，仍然不是"别的客户端收到了"。** 后者见 §6.1。

**用户视觉确认：** 用户主动报告"我看到你发了 autotest 啥的的信息"，即这条消息
出现在他自己的聊天栏里。

---

## 4. 测试路径上修掉的两个真实缺陷

都是**只有实机才会暴露**的，离线测试抓不到：

| 缺陷 | 现象 | 修法 |
| --- | --- | --- |
| `ffi.cast` 类型写成 `void *` | `cannot convert 'number' to 'void *'`：LuaJIT 不允许把 Lua 数字传给 `void *` 形参。这是 **Lua 级错误**，被 `pcall` 兜住，所以表现为干净的拒绝而不是崩溃 | functype 形参改 `uint64_t` |
| 环形读取取"第一段可打印字节" | entry 开头是指针和记账字节，其中一些恰好可打印，于是打印出 `p_` 这种噪音而不是消息 | 改为取**最长**可打印段 |

第一条尤其值得记：**`pcall` 把原生调用错误变成了干净拒绝，代价是这个缺陷对任何离线
测试都不可见**。

---

## 5. 与"进不去游戏"的关系（负向证据）

用户报告"无法和服务器连接"。为排除本模组，**把模组整个回退后再启动**：

```text
Startup finished: 61 loaded, 0 failed       <- 本模组不在其中
auto_chat present in this boot: False
```

模组缺席时该现象依然存在。同时：

- 游戏目录层文件数 **707 = 安装前的 707**
- `game.dll` 哈希与安装前逐字节一致
- 最近一小时**无新增崩溃转储**

此外机器上同时运行着**三套会抢游戏流量的工具**：`clash-verge`
（系统代理）、`uu` 系列（UU 加速器）、`RvRvpnGui`（Radmin VPN）。
这是"无法连接服务器"更合理的解释，且与模组无关——本模组只读写游戏内存，
不发起也不拦截任何网络请求。已建议用户只保留其中一套。

---

## 6. 没有验证的部分（不要当成已完成）

### 6.1 网络投递：别人是否收到

**未验证。** 整场会话 `peer count` 读到的**始终是 0**，本机只有一个玩家。向只列出
自己的会话发送，按构造就到达不了任何人。因此上面的成功只覆盖到"游戏接受了这条消息"，
**不覆盖"别的客户端收到了它"**。

要验证它，需要小队里真的还有一个人：

```powershell
python -B tools/watch_for_squad.py
```

这个脚本会等到 `peer count >= 1`，然后走**正常路径**（不绕过守卫）发一条，并把游戏
自身的 before/after 打出来。成功的标志是 `history` 前后不同，**再加上那名玩家口述
他看得见**——最后这一条是人的观察，脚本产生不了。

### 6.2 其他未验证项

- 没有实机进过任务（只在舰船/菜单层）。
- 发送瞬间键鼠是否真的不受影响——**没有在发送成功的同一时刻实测过**；
  模组本身不碰输入，但这是推理，不是观测。
- 聊天开关语义（`(raw % 256) == 0` 是否真等于"聊天关闭"）是参考模组的说法，
  本仓库没有独立验证。
- `send` 第二个参数传 `0`，照抄参考调用点，**含义未查证**。
- 环形 entry 里 `entry+0x208` 之外的结构（发送者名字、时间戳等）没有解析。
- `inspect` 命令读聊天对象窗口时返回 0 段可读文本，原因未查明。

---

## 7. 复现命令

```powershell
# 门禁 + 40 项离线测试
python -B work/standalone/build_mod.py --validate-only
python -B -m unittest discover -s work/standalone/tests -p "test_*.py"

# 打包
python -B work/standalone/build_mod.py

# 部署 / 查看 / 回退
python -B work/standalone/deploy.py --deploy   --slot 336
python -B work/standalone/deploy.py --status   --slot 336
python -B work/standalone/deploy.py --rollback --slot 336

# 实机诊断（游戏运行时）
python -B tools/send.py ring            # 环形历史与每行内容
python -B tools/send.py "find <文本>"    # 在聊天对象里逐字节搜索
python -B tools/send.py --status        # 只看 STATUS 与最近日志

# 多人验证（需要第二名玩家）
python -B tools/watch_for_squad.py
```
