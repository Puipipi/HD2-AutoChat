# 自动聊天 / AutoChat

一个 Helldivers 2 的 Bingus/MDL 加载器模组：**不打开聊天栏，直接把文字聊天发给小队。**

"玩家被聊天栏卡住"是聊天框**夺取键鼠**造成的；而发消息只需要它最后一步——
调用发送函数。所以不需要那个框在场，也就没有输入锁。

| 项 | 值 |
| --- | --- |
| 版本 | 0.2.1（可发送） |
| 资源名 | `mods/codex/auto_chat` |
| GUID | `a1000000-0000-4000-8000-000000000022` |
| 前置 | Bingus Shared Loader v15+ / API 1 |
| 目标 build | Steam build 25480438 / EXE 1.8.46015.0 |

> **发送路径的最后一跳尚未实机验证。** 原因是本机全程单人（`peer count = 0`），
> 模组按设计拒绝向空会话发送。签名匹配与函数解析**已**实机验证。见
> [实机取证](docs/LIVE-EVIDENCE-2026-10-08.md)。

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

1. 把 `dist/AutoChat-0.2.1.zip` 导入模组管理器，启用 **AutoChat** 与
   **Bingus Shared Loader**，部署。
2. 进游戏，**确保小队里至少还有一名其他玩家**。
3. 用随仓库的脚本发（它写触发文件、等一会儿、再把日志贴回来）：

```powershell
python -B tools/send.py 1433223        # 把这段文字作为一条聊天发出去
python -B tools/send.py inspect        # 不发送，改为倾倒聊天对象里的可读文本
python -B tools/send.py find 1433223   # 在聊天对象里搜这段字节，报告命中位置
python -B tools/send.py --status       # 只看 STATUS 和最近日志，什么都不发
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

**实机验证过（2026-10-08，build 25480438）：**

- 游戏正常启动进入游戏，加载器 **62 loaded / 0 failed**（装之前 61/0）。
- 5 段签名在实机进程里**全部匹配** —— 这些偏移对这版二进制有效。
- `send ready : true`：发送函数在真实进程里解析成功（已验证地址 → 可调用指针）。
- 聊天开关字节从 `0` 变到 `1`，是真实动态字段而非常量。
- `inspect` 可读聊天对象（扫了 4096 字节）。
- 两次会话合计约 45,000 帧 / 23 万次读取，**errors = 0**，无新崩溃转储，正常退出。

**没有验证：**

- **发送本身。** 全程单人（`peer count = 0`），发送在 `nobody else in the session`
  被拒——设计内行为，但意味着**最后一跳从未执行**。
- **没有实机进过任务、没有和任何其他玩家同队。**
- 发送时键鼠是否真的不受影响，**没有在发送瞬间实测过**（没有发送成功过）。
- 聊天开关语义（`(raw % 256) == 0` 是否真等于"聊天关闭"）是参考模组的说法，
  本仓库**没有独立验证**；探针只记原始值。
- `send` 的第二个参数传 `0`，是照抄参考调用点；**它的含义没有查证过**。
- `M.LOCAL (0xb398)` 只读了低 32 位；参考模组比较完整 u64。低 32 位相同而高
  32 位不同会误判，本机无法构造这种情形来验证。
- 聊天历史的**正文**布局没有解析（`inspect` 只是暴力扫可读字节串）。

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
