# 第三方说明 / Third-Party Notices

## 1. 偏移与机器码记录的来源

本模组最初的聊天发送地址（RVA）与用于校验的机器码字节，**取自第三方模组
`better_lobby_management`（作者 cowboybingus）的公开源码记录**，不是本仓库
自行逆向得出的。0.7.0新增的地图、颜色、缩写与本地化字段另经当前DLL指令交叉验证，见下文。

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

## 面板输入与会话接口参考

面板布局、光标交接、Raw Input 归还与原生窗口消息过滤代码，参考 Super Earth Armory Forge
v6.2.1。其面板注明源自 SHODAN Stat Editor v1.4.1（public domain / Unlicense）：
https://github.com/SHODAN-HORAI/SHODAN-Stat-Editor 。原生过滤页仅由本进程分配，
关闭时停用，保留内存供其他模组已串联的窗口过程使用，不修改游戏代码或数据。
独立输入控制器片段会与内嵌版本逐字节比对，原生字节码另有模拟执行测试。

主机身份与玩家列表使用游戏自身 stingray.Network / stingray.GameSession API，调用方式参考
本地 P2P-Ping 0.1.34；本模组不依赖 P2P-Ping 安装或运行。

标记分类调查读取了用户已安装的 Custom UI、Better Map Markers 的资源表与 manifest；
这些包只含材质与贴图，本仓库不复制或重新分发其图标资源。

## 4. 没有做的事

- 不修改、不重打包、不重新分发游戏本体任何文件。
- `user32` 的面板/剪贴板声明先检查是否已有声明，仅补充缺失项，原型与 Armory Forge
  对齐并由构建门禁核对，避免进程级 C 命名空间中的共享原型冲突。
- 不声明任何进程内存**写**原语（`WriteProcessMemory` / `VirtualProtect` /
  `VirtualAllocEx` / `CreateRemoteThread` 等一个都没有）。构建脚本会在出现时
  拒绝打包。

## 原生标记读取的参考

0.7.0 的特殊身份另参考 HD2Runtime `sdk/SupportWeaponCapabilities.json`、RawData
`EntityComponentMap`/`EncyclopediaEntry` 与 FileDiver 路径。历史 `HudMarkerType` 的
kind21与当前DLL地图生产/接收指令交叉验证，不将贴图hash当事件枚举。
本地化签名/ABI参考本地 Foundation `Localization.bind`、`extra_localized_text`，仅保留机器码事实与重新实现的读取桥。
队友缩写及颜色参考P2P-Ping调查思路，实际字段/颜色表从当前游戏聊天HUD核对；未复制其估计槽位算法。
完整读取链、资源范围、原生调用边界见 `docs/PING-CLASSIFICATION-0.7.0.md`。

- [HD2-G60-Smart-Targeting native_ping.lua](https://github.com/etxp/HD2-G60-Smart-Targeting/blob/main/src/g60/native_ping.lua)
  与 native_target_data.lua：读取偏移、环形记录与实体描述布局事实；本项目重新实现读取、边界、归属及基线逻辑。
- [HD2Runtime event_world.lua](https://github.com/SkyeShade/HD2Runtime/blob/master/runtime/event_world.lua)
  与 domains/event_natives.lua：同一 game.dll 指纹下的玩家、角色、peer 字段布局事实。
- [Helldivers2_RawData](https://github.com/Darctor/Helldivers2_RawData/tree/main/Data/entities)：
  AiEnemyComponentData / HealthComponentData.unit_size 与 UnitSize 枚举事实，和当前版本实体清单交叉核对。
  敌人名称与资源ID为事实表，未知类型不推断体型。小物品使用 EncyclopediaEntry 与
  Spottable/Interactable/Loot 组件交叉确认；任务实体与
  [FileDiver资源路径](https://github.com/xypwn/filediver/blob/master/hashes/hashes.txt)及
  EntityComponentMap的Spottable/Objective组件交叉确认，排除教程与非任务模型。

etxp 参考源码的许可全文同时保留在 src/ping_events.lua 的内嵌片段中，因此随模组归档源码分发：

```text
MIT License

Copyright (c) 2026 etxp

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
