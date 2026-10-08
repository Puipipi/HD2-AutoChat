# 自动聊天 / AutoChat

一个 Helldivers 2 的 Bingus/MDL 加载器模组：**不打开聊天栏，直接把文字聊天发给小队。**

"玩家被聊天栏卡住"是聊天框**夺取键鼠**造成的；而发消息只需要它最后一步——
调用发送函数。所以不需要那个框在场，也就没有输入锁。

| 项 | 值 |
| --- | --- |
| 版本 | 0.2.6（可发送） |
| 资源名 | `mods/codex/auto_chat` |
| GUID | `a1000000-0000-4000-8000-000000000022` |
| 前置 | Bingus Shared Loader v15+ / API 1 |
| 目标 build | Steam build 25480438 / EXE 1.8.46015.0 |

> **已实机验证：同小队的另一名玩家（另一台机器、另一个人）看到了消息 —— 两个方向都确认了。**
> 本机当主机发 10 条、再当客机发 10 条，全部走**正常路径**（一次都没用强制旁路），
> 游戏自身 `history` `0/5 → 0/37`，对端两次都当场确认聊天栏里出现了这些消息
> （`他看到了` / `可以，都能看到`）。
> 见 [多人投递验证](docs/LIVE-EVIDENCE-MULTIPLAYER-2026-10-08.md)。
>
> 发送路径本身另有机器码级证明：反汇编**聊天框自己的调用点**后，网络上下文全局
> `game.dll+0x347CEF0`、聊天对象偏移 `+0xC418`、发送函数 `game.dll+0x1097560`
> 三个地址与本模组使用的**完全相同** —— 走的是你手打一条所走的同一条路径，
> 不是本地自绘/回显。可用 work/standalone/tools/verify_send_site.py 重复核对。
>
> **仍未验证**：只测过 **1 名**对端（3–4 人小队未测）；"以 -1 广播给所有对等端"
> 仍是照抄第三方的说法、没有独立追证。详见文末未验证清单。

---

## 为什么能绕开聊天栏

游戏自己的聊天框做四件事：**夺取键鼠 → 画个框 → 收集按键 → 调用发送函数**。

前两件就是"卡住"的来源。发送本身只是把一段文本交给一个函数：

```text
ctx + 0xC418                      网络上下文里的聊天对象
game.dll + 0x1097560              LmChatSend(chat, 0, text_buffer)
```

这是聊天框**自己也调**的同一套东西（`game.dll+0x186025d` 就是聊天框的调用点）。

这不是推测：第三方模组 `mods/cowboybingus/better_lobby_management` 已经这么
发小队消息了。本仓库的偏移与机器码**全部取自它的源码记录**，没有自己猜。

---

## 安全设计：先验证，再调用

模组的所有绝对地址都是**某一版二进制**的观测值，游戏一更新就全废。拿一个没验证
的地址去调用，轻则"装上了但什么都不做"，重则在 `game.dll` 里 fault 把进程带走——
而 `pcall` **抓不住原生崩溃**。所以顺序是硬性的：

1. **启动时校验 5 段机器码前缀**（下表）。任何一段不符 → 整局停手，日志写明
   **是哪一段**、期望值与实际值各是什么。不符之后本文件里**任何**偏移都不会被使用。
2. 只有校验通过，才 `ffi.cast` 出可调用的发送函数指针。
3. 每次发送前再判断：网络会话存在、聊天对象可读、游戏自己的聊天开关是开的。
4. 发送用 `pcall` 包住——但**不把 pcall 当安全网**，它只拦 Lua 级错误。

| RVA | 内容 | 校验长度 |
| --- | --- | --- |
| `0x1097560` | 聊天发送函数 | 32 字节 |
| `0x0bde430` | RPC 发送 | 28 字节 |
| `0x186025d` | 聊天框的调用点 | 21 字节 |
| `0x0beb103` | 聊天消息 RPC 构造 | 16 字节 |
| `0x1097a7c` | 聊天历史读取 | 12 字节 |

**为什么不是整段都校验：** 字节串里有一部分是 `call rel32` 的**相对位移**，
重链接会让它变，而它变不变跟"这还是不是同一个函数"无关。断言一段没人推理过的
字节，会把一次无害的重链接报成"签名变了"——最贵的假警报，因为它让你去查游戏，
而问题在自己的文件里。校验长度只到**含义被真正理解**的那一段为止。
`tests/test_signature_provenance.py` 会离线核对每个字节是否与参考源码逐字节一致，
并断言前缀不超过上表长度。

### 跨模组 `ffi.cdef` 冲突

LuaJIT 的 C 命名空间是**进程级**的，且 `ffi.cdef` **保留第一次声明**。所以本模组
声明的原型必须和其他模组一致，否则调用约定不符、守卫失效。最危险的是
`VirtualQuery`：本工作区**多数**模组声明它返回 `size_t`（成功时 48）。

```lua
size_t VirtualQuery(const void *address, void *info, size_t length);
```

本模组采用这个多数写法，并拿返回值与 `MBI_SIZE`(48) 比较，而**不是**与 `0` 比较。
用 `== 0` 判失败在另一种原型下会读错返回值，页守卫就会停止守卫——那正是会产生
崩溃的状态。`M.REGION_PROBE` 之外的读取一律先过页状态检查（已提交、非 guard）。

---

## 怎么用

1. 把 `dist/AutoChat-0.2.6.zip` 导入模组管理器，启用 **AutoChat** 与
   **Bingus Shared Loader**，部署。
2. 进游戏，**确保小队里至少还有一名其他玩家**。
3. 用随仓库的脚本发（它写触发文件、等一会儿、再把日志贴回来）：

```powershell
python -B tools/send.py 1433223        # 把这段文字作为一条聊天发出去
python -B tools/send.py inspect        # 不发送，改为倾倒聊天对象里的可读文本
python -B tools/send.py find 1433223   # 在聊天对象里搜这段字节，报告命中位置
python -B tools/send.py --status       # 只看 STATUS 和最近日志，什么都不发
python -B tools/send.py ring           # 打印聊天历史环形缓冲与每行内容
python -B tools/send.py "find 1433223"  # 在聊天对象里逐字节搜索，报告命中位置
python -B tools/send_and_verify.py 1433223   # 发送并对比游戏自身的 before/after
python -B tools/watch_for_squad.py     # 等到小队里真有人，再走正常路径发一条

# 从内存转储反汇编，证明我们调的就是聊天框调的那个函数
# python -B work/standalone/tools/verify_send_site.py --dump <section0.bin> --headers <headers.bin>
```

或者手工把一行文字写进：

```text
%LOCALAPPDATA%\CowboyBingus\Helldivers2\AutoChat\trigger.txt
```

第一行非空内容会被发送一次，然后文件被清空；要再发一遍就再写一次。
写 `inspect` 则**不发送**，改为把聊天对象里所有可读文本段倾倒进日志——
这样不用第二个玩家也能确认聊天通道在读。

**发送要求小队里至少还有一名其他玩家。** 只有你一个人的话会得到
`nobody else in the session`——这是设计内的拒绝，不是故障。

4. 看日志：

```text
%LOCALAPPDATA%\CowboyBingus\Helldivers2\Logs\AutoChat.log
%LOCALAPPDATA%\CowboyBingus\Helldivers2\AutoChat\AutoChat-STATUS.txt
```

**成功的标志是 `history` 前后不同**——例如
`sent 7 bytes; history 0/0 -> 0/1`。那是游戏自己承认这条消息进了聊天，
而不是模组自称发出去了。

日志是 UTC，北京时间 = UTC+8。启动时记一次观测，之后**只在游戏自己的值变化时**
才再记，外加每 ~30 秒一条心跳。所以**静止的日志不代表没跑**——看 STATUS 的
`frames` 和 `reads`。

### 发送被拒绝时日志会写明原因

| 日志 | 含义 |
| --- | --- |
| `nobody else in the session` | 小队里只有你（**最常见**，不是故障） |
| `text chat is off` | 游戏自己的聊天开关是关的 |
| `no network session` | 还没进入任何会话 |
| `signature not verified` | 签名校验没过，整局禁用发送 |

---

## 已验证 / 未验证

> **已实机验证：同小队的另一名玩家（另一台机器、另一个人）看到了消息。**
> 10 条走正常路径，游戏自身 `history 0/5 → 0/17`，对端当场确认。
> 详见 [多人投递验证](docs/LIVE-EVIDENCE-MULTIPLAYER-2026-10-08.md)。

**实机验证过（2026-10-08，build 25480438）：**

- **另一名玩家（另一台机器）看到了消息 —— 两个方向都确认**：本机当主机发 10 条、
  再当客机发 10 条，全部正常路径，`history 0/5 → 0/37`，对端两次都当场确认
  （`他看到了` / `可以，都能看到`）。
- 游戏正常启动进入游戏，加载器 **62 loaded / 0 failed**（装之前 61/0）。
- 5 段签名在实机进程里**全部匹配** —— 这些偏移对这版二进制有效。
- `send ready : true`：把已验证的绝对地址成功转成可调用的函数指针。
- **游戏自己接受了消息**：`history` 一路递增到 `0/30` 以上，多次会话累计 35+ 条。
- 发送文本在聊天对象里定位到 `chat+0xBA0 / +0xDC8 / +0xFF0 / +0x1218`，
  **间隔 0x228**，与从游戏自身历史访问器读出的槽步长一致；文本落在 `entry+0x208`。
- 调用目标经反汇编核对为 `game.dll+0x1097560`，与**聊天框自己调用的那个函数**是同一个。
- **用户视觉确认**消息出现在聊天栏；发送期间帧率稳定（69–82 fps）、无卡顿。
- **性能开销：6.000 → 0.200 reads/frame**（0.2.7 修掉每帧约 10 次堆分配）。
- 累计约 20 万帧，**errors = 0**，无新崩溃转储，均正常退出。
- 回退后游戏目录层文件数回到 **707**，与安装前记录的 707 一致；`game.dll` 哈希不变。

**没有验证：**

- **只测过 1 名对端。** 3–4 人小队未测，"广播给所有对等端"里的"多"这一层没测到。
- **`ctx+0x16390`（`PEER_COUNT`）在主机与客机两种角色下都读到 0**，尽管会话里
  确实有 1 名对端。发送守卫能正确放行靠的是 `other_peers()` 的枚举，不是这个字段。
  所以**不要用 `PEER_COUNT` 判断"会话里有没有人"** —— 两种角色下都会漏。
- **"以 -1 广播给所有对等端"是照抄参考模组的说法，本仓库没有独立验证。**
  我确认发送函数入口处确实有一条 `mov edx, 0xffffffff` 紧跟一次 `call`，
  但那个 callee 落在虚拟化节（`.winlice` / `.vm_sec`）上、无法可靠静态追踪，
  所以**指令看到了、含义没有追证**。
- **主机侧 `ctx+0x16390`（`PEER_COUNT`）在本次会话里始终读 0**，尽管会话里确实有
  1 名客机。发送守卫能正确放行靠的是 `other_peers()` 的枚举，不是这个字段。
  所以**用 `PEER_COUNT` 判断"会话里有没有人"在主机上是错的** —— 这条只观测到
  一次，没有第二次复现。
- 客机发送（本机当客机、对方当主机）未测。
- 发送瞬间键鼠是否不受影响：帧率无抖动、模组不声明任何输入符号，但**没有做
  键盘级实测**。
- 聊天开关语义（`(raw % 256) == 0` 是否真等于"聊天关闭"）是参考模组的说法，
  本仓库没有独立验证；探针只记原始值。
- `send` 的第二个参数传 `0`，照抄参考调用点，**含义未查证**。
- 环形读取器目前**是坏的**（entry 基准地址算错，打印出 `p_` 之类噪音）；
  `find` 逐字节搜索是准的，`ring` 的输出在修好前不可信。
- `inspect` 读聊天对象窗口只找到部分消息，窗口大小不足以覆盖整个环。

---

## 构建与测试

```powershell
# 门禁：LuaJIT 编译 / 无 user32 / 调用⊆声明 / 无内存写原语 / 检测活性 / README 块
python -B work/standalone/build_mod.py --validate-only

# 全部离线测试（29 项）
python -B -m unittest discover -s work/standalone/tests -p "test_*.py" -v

# 打包 -> work/standalone/dist/AutoChat-<version>.zip
python -B work/standalone/build_mod.py

# 部署 / 查看 / 回退（脚本先核对哈希，不是自己的文件就拒绝）
python -B work/standalone/deploy.py --deploy   --slot 336
python -B work/standalone/deploy.py --status   --slot 336
python -B work/standalone/deploy.py --rollback --slot 336
```

### 门禁曾经**不可能失败**

`work/standalone/gates.py` 被拆成独立模块，唯一理由是：内联的门禁无法被证明会
失败，而这里有三条**曾经根本不可能失败**：

- **user32 门禁**只认得 `ffi.cdef[[...]]`，而本工作区写的是
  `pcall(ffi.cdef, [[...]])` —— 它找到 **0 个** cdef 块，于是无论文件声明了
  什么都报 "no user32"。
- **"调用必须先声明"门禁**的正则 `\b(?:k|u|kernel32|…)\.` **永远匹配不到
  `kernel.Foo(`**：交替分支在 "kernel" 的第一个字母 `k` 上就成功了，紧接着却
  要求一个 `.`，而那里是 `e`。它在调用 `kernel.ReadProcessMemory` 五次的文件上
  报告 "none"。
- 两条合起来的效果是**"什么都没找到 = 全部通过"**。

现在多了一条 `check_detection_is_live`：**一个正则什么都没匹配到，构建直接失败**，
而不是报成功。`tests/test_build_gates.py` 对每一条门禁都喂一份违规源码，断言它
被拒绝；其中两个测试专门把上游那条**匹配不到**的正则跑一遍并断言它返回空，
把这个 bug 本身钉在测试里。

---

## 第三方与许可

- 偏移与机器码记录取自 `mods/cowboybingus/better_lobby_management`（第三方，
  只读参考，本仓库**不再分发**其源码）。
- `work/standalone/vendor/bingus/` 的 `build_addon.py` / `archive.py` 是加载器作者
  的信封包工具，属于**构建依赖**，不随本仓库分发。见 `THIRD_PARTY_NOTICES.md`。
- 本模组自己的源码许可见 `LICENSE`。

## 目录

```text
auto-chat/
├─ src/auto_chat.lua                 模组源码（纯文本 UTF-8，无 BOM）
├─ work/standalone/
│  ├─ build_mod.py                   门禁 + 打包
│  ├─ gates.py                       门禁实现（可测）
│  ├─ deploy.py                      部署 / 查看 / 回退（核对哈希）
│  └─ tests/                         29 项离线测试
├─ work/deploy/                      部署记录与安装前基线
├─ docs/LIVE-EVIDENCE-2026-10-08.md  实机取证
└─ dist/                             产出的 ZIP
```
