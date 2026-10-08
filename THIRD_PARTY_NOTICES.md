# 第三方说明 / Third-Party Notices

## 1. 偏移与机器码记录的来源

本模组的全部绝对地址（RVA）与用于校验的机器码字节，**取自第三方模组
`better_lobby_management`（作者 cowboybingus）的公开源码记录**，不是本仓库
自行逆向得出的。

读了什么：

- 聊天对象偏移（`ctx + 0xC418`）、发送函数 RVA（`0x1097560`）及其字节串
- RPC 发送 RVA（`0xbde430`）、聊天框调用点（`0x186025d`）、
  聊天消息 RPC（`0xbeb103`）、聊天历史读取（`0x1097a7c`）
- 网络上下文指针（`0x347cef0`）与会话/peer 布局（`0x16390` / `0x16398` / 步长 32）

本仓库的做法与边界：

- **不分发**该模组的任何源码。本地参考件位于工作区的
  `outputs/validated-2026-10-05/.../mods__cowboybingus__better_lobby_management.lua`，
  它**不在**本仓库内，也不在公开快照里。
- `work/standalone/tests/test_signature_provenance.py` 会在**参考件存在时**逐字节
  核对本模组记录的字节串与参考源码是否一致；参考件不存在时该测试**跳过**而不是
  静默通过。
- 这些偏移是**参考模组对某一版二进制的观测值**，不构成任何保证。本模组因此把
  "签名校验" 做成硬前置：对不上就整局停手。

## 2. 构建依赖（不随本仓库分发）

`work/standalone/vendor/bingus/` 下的：

- `build_addon.py`
- `archive.py`

是 **Bingus 加载器作者提供的信封包构建工具**，编码了加载器读取的归档格式。
它们属于**构建依赖**，地位等同于编译器：本仓库不拥有其版权，也不随源码分发。
公开快照中**刻意不包含**这两个文件。

要自行构建，请从加载器作者处获取这两个文件并放入
`work/standalone/vendor/bingus/`。

## 3. 运行期依赖

- **Bingus Shared Loader** v15 或更新（API 1）—— 本模组通过
  `_G.CowboyBingusModLoader` 与之交互。
- 无其他运行期依赖。不加载任何第三方 Lua 库。

## 4. 没有做的事

- 不修改、不重打包、不重新分发游戏本体任何文件。
- 不声明任何 `user32` 符号（LuaJIT 的 C 命名空间是进程级的，重复声明会静默废掉
  别人的声明——见工作区的失败手册 §2）。
- 不声明任何进程内存**写**原语（`WriteProcessMemory` / `VirtualProtect` /
  `VirtualAllocEx` / `CreateRemoteThread` 等一个都没有）。构建脚本会在出现时
  拒绝打包。
