# AutoChat 接口示例插件

这是一个独立的 Bingus addon，依赖 Shared Loader v15+ 与 AutoChat API v2 revision 3。它在“设置”旁注册“接口示例”页，演示主设置快照、继承与独立发送策略以及安全的 UI 绘制接口。源码位于 [`src/examples/interface_demo.lua`](../src/examples/interface_demo.lua)，构建脚本位于 [`tools/build_interface_demo.py`](../tools/build_interface_demo.py)。

示例页提供发送模式切换、独立发送启用开关、独立冷却 0/5 秒切换、独立输出继承/仅自己切换、自定义消息模板切换和手动发送按钮。继承发送走原 API v2 默认行为；独立发送明确传入自己的 `enabled`、`cooldown`、`cooldown_key`、`allow_solo` 与 `output`。独立策略可以绕过宿主总开关和宿主全局冷却，但仍接受会话、身份、消息和发送器校验。关闭示例自己的独立发送开关时，示例会在调用宿主前拒绝发送；该开关也会把手动发送按钮置灰。独立冷却桶彼此隔离，请求不会排队；本地发送失败不会回退公屏。

页面展示 `api.settings()` 的当前配置快照中的主开关、间隔、输出模式、角色与语言。页面和标签会跟随当前语言切换，固定插件文案提供中英版本；用户自定义消息保持原样。该快照只读；不可用于修改宿主状态。示例通过 `u.line` 和 `u.icon` 演示绘图。图标只取宿主可选提供的 `u.loaded_icon`（UI context 的 `loaded_icon`），即当前 catalog 中已确认加载的游戏材质；没有资源时显示说明文字。`u.image`/`u.icon` 不支持任意磁盘图片或插件自行加载文件。

`u.line` 是通过矩形绘制近似线段，不是原生矢量线条：水平/垂直线使用一个矩形，斜线由离散矩形点组成，最多 512 个点，超长线段会被拒绝。

示例不订阅实时游戏事件，不进行额外游戏轮询，也没有自动发送。所谓“本地示例事件”由插件自己的点击处理器生成，只在用户点击发送按钮时通过当前 API 调用发送接口。

构建包会写到仓库的 `dist/AutoChat-Interface-Demo-1.0.0.zip`：

```powershell
python -B tools/build_interface_demo.py
```

资源路径为 `mods/codex/auto_chat_demo`，GUID 为 `a1000000-0000-4000-8000-000000000023`。独立 contract 测试使用真实 Lua 示例源码和离线 fake API/UI 验证交互参数及打包内容；mock 测试不代表 Loader 或游戏内的实际验证。
