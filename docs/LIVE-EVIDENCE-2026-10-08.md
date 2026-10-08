# 实机取证 2026-10-08

机位：build 25480438 / EXE 1.8.46015.0，`game.dll` SHA-256
`2E2C3B7C2500646DADD5F2B4C6E0504DBB7E7896139F64CDDC0D1813C718F51E`。

时间戳全部是 UTC，本地时间 = UTC+8。

---

## 1. 部署方式

槽位 336（`data\9ba626afa44a3aa3.patch_336`）。装之前游戏目录里
`9ba626afa44a3aa3.patch_*` 是 0..335 共 336 个，**没有空位**，所以新层就是 336。
装之前记录的基线在 `work/deploy/before-layers.json`（707 个层文件）与
`before-gamedll.sha256`。

回退方式：`python work/standalone/deploy.py --rollback --slot 336`
（脚本会先核对哈希，确认这个槽位确实是本模组写的才动）。

---

## 2. 0.1.0（只读探针）实机结果

加载器：

```text
mods/codex/auto_chat: loaded
  changes: heap +52 KB, 3 ms; added HD2AutoChat; replaced shutdown, update
Startup finished: 62 loaded, 0 failed      <- 装之前是 61 loaded, 0 failed
```

探针首轮观测（`Logs\AutoChat.log`）：

```text
signature check: PASS
  all 5 code signatures match
observation [observed]
  network context: 0x26387415F70
  peer count: 0 (max observed layout 4)
  chat flag byte: 0 -> 1
  chat history: first=0 count=0 (plausible 64-line ring: true)
```

会话结束时的结算行：

```text
shutdown: frames=29598 reads=177593 bytes=621667 errors=0 last verdict: observed
```

**结论：** 5 段机器码签名在本 build 上**全部匹配**——参考模组记录的这些偏移，
到这版二进制为止仍然有效。聊天开关字节是一次真实的状态跃迁（`0` → `1`，
网络会话建立后文字聊天转为可用），不是常量。整个会话零错误。

`peer count` 全程 0：单人，机器上只有一个玩家。所以"和别的玩家同队"这件事
**本机没有验证过**。

---

## 3. 0.2.0（可发送）实机结果

```text
Startup finished: 62 loaded, 0 failed
status      : observing (read-only)      <- 这一行是 0.1.0 遗留的字符串，0.2.1 已修
signature   : match
send ready  : true                       <- 发送函数在真实进程里解析成功
messages sent: 0
frames      : 16200
reads       : 54005
errors      : 0
```

**`send ready : true` 的含义要说清楚：** 它证明 `ffi.cast` 把一个**已验证**的
绝对地址成功地变成了可调用的函数指针——也就是"这个地址在这版二进制上确实可以
当函数调"。它**不**证明调用它就一定能成功发出消息，因为那需要在有第二名玩家的
会话里真的调一次。

`inspect` 通道实机验证：

```text
inspect: scanned 4096 bytes of the chat object, 0 readable run(s)
```

聊天对象可读，扫了 4096 字节；0 段可读文本与"单人、聊天历史为空"一致。

**没有验证：发送本身。** 从头到尾 `peer count = 0`，没有第二名玩家，`send_text`
因此在 `nobody else in the session` 这一条上被拒绝——这是设计内的行为，不是
故障，但它意味着**发送路径的最后一跳从未执行过**。

---

## 4. 游戏健康

- 两次启动都正常进到游戏（主菜单渲染正常，128 FPS / 5.3 GB / 8.0 GB）。
- 两次会话合计约 45,000 帧、23 万次读取，**errors = 0**。
- 没有产生任何新的崩溃转储（`%LOCALAPPDATA%\CrashDumps` 里最新的仍是
  2026-10-07 21:41，属于本模组安装之前）。
- 游戏以正常方式关闭（`CloseMainWindow`，4 秒退出），没有强杀。

---

## 5. 下一步要什么才能把"能发"变成已验证

1. **至少两名玩家在同一小队**（`peer count >= 1`）。
2. 把一行文字写进
   `%LOCALAPPDATA%\CowboyBingus\Helldivers2\AutoChat\trigger.txt`。
3. 日志应出现 `trigger: sending N bytes: ...`，随后
   `sent N bytes; history A/B -> C/D`。**`history` 前后不同**才是游戏自己承认
   这条消息进了聊天——那才算证据。
4. 同时确认：发送瞬间键鼠没有被夺走、聊天栏没有出现。

如果日志写的是 `nobody else in the session`，那就是当时确实只有你一个人，
不是模组坏了。
