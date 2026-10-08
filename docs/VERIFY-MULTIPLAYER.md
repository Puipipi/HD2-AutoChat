# 多人投递验证 runbook

这份文档只解决**一个**问题：**别的玩家到底收不收得到 AutoChat 发的消息。**

这是本模组唯一没有验证的部分，原因很简单——本机全程只有一个玩家，
`peer count` 20 次读数全是 0，而向一个只列出自己的会话发送，按构造到达不了任何人。

**不需要改任何代码。** 照下面做一遍就有答案。

---

## 已经确定的部分（不用再验）

| 断言 | 证据 |
| --- | --- |
| 调的是**聊天框自己调的那个函数** | 反汇编聊天框调用点，`call` 解析结果 = `game.dll+0x1097560`，与模组调用目标一致；参数同样是 `rcx=ctx+0xC418`、`r8=文本缓冲` |
| 游戏**接受**了消息 | 游戏自身 `history` 计数 `0/0 → 0/1 → … → 0/4` |
| 文本确实进了聊天对象 | `find` 逐字节命中于 `chat+0xBA0 / +0xDC8 / +0xFF0 / +0x1218`，间隔 0x228 |
| 不崩 | 累计约 40 万帧 / 230 万次读取，`errors=0`，无新增崩溃转储 |

**没确定的只有一件事：对等端是否收到并显示。**

---

## 需要什么

- 游戏能连上服务器（若报"无法和服务器连接"，先看 [故障排查](#连不上服务器时)）
- **小队里至少还有一名其他玩家。** 随便进一局公开任务、里面有随机路人即可；
  或者拉一个好友进你的小队。
- AutoChat 与 Bingus Shared Loader 已启用并部署

---

## 做这一件事

在小队里（按 `Tab` 或看向队友能确认人数），运行：

```powershell
python -B tools/watch_for_squad.py
```

它会：

1. 每 3 秒读一次模组日志里的 `peer count`
2. 一旦 `peer count >= 1`，走**正常路径**（不绕过守卫）发一条 `AUTOCHAT-CHECK`
3. 把游戏自己的 before/after 打出来

### 通过的样子

```text
AutoChat says signature: match
waiting for a squad with at least one other player ...

  peer count = 1   <- squad detected

squad detected (1 other player(s)). sending 'AUTOCHAT-CHECK' ...

  trigger: sending 15 bytes: AUTOCHAT-CHECK
  sent 15 bytes to 1 other player(s); history 0/0 -> 0/1

RESULT: the game recorded the line. history 0/0 -> 0/1
        Now ASK THE OTHER PLAYER whether they can see it.
```

### 还差最后一格

**问那个队友：聊天栏里有没有出现 `AUTOCHAT-CHECK`。**

- **他说有** → 网络投递验证通过，目标达成。
- **他说没有** → 说明消息只进了本机聊天对象、没有发到对等端。
  这不是崩溃，是功能没做到；把日志和这句话一起发我，我继续查。

`history` 变化 + 队友亲口确认，两条**都要**才算通过。脚本只能给你第一条。

---

## 如果脚本说 "still alone"

说明那一刻小队里确实没有别人，不是模组坏了。正常路径会被拒绝并写明
`nobody else in the session`。等队友进来再跑一次。

## 如果脚本说 "dormant"

签名没对上（游戏更新过），模组整局不发送。日志里会写明是哪一段变了。

---

## 连不上服务器时

这与本模组无关，已用负向证据确认：**把模组整个回退后再启动，该现象依然存在**，
且加载器显示 61 loaded / 0 failed（没有 `auto_chat`）。

本机上同时跑着三套会抢游戏流量的工具，这是更合理的解释：

| 进程 | 类型 |
| --- | --- |
| `clash-verge`, `clash-verge-service` | 系统代理 |
| `uu`, `uu_ball`, `uu_cloudsyn`, `uu_launcher`, `uu_neths_helper` | UU 加速器 |
| `RvRvpnGui` | Radmin VPN（虚拟网卡） |

建议**只保留一套**（如果你平时用 UU，就先关掉 clash-verge），再启动游戏。

模组只读写游戏内存，不发起也不拦截任何网络请求。

---

## 回退模组

```powershell
python -B work/standalone/deploy.py --rollback --slot 336
```

脚本先核对哈希，确认该槽位确实是本模组写的才动手。
实测回退后游戏目录层文件数回到 **707**，与安装前一致。
