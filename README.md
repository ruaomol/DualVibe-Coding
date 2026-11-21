# DualVibe Coding

[English](README.en.md)

DualVibe Coding 是一款只面向 macOS 的 DualSense 控制器工作台。它把手柄输入、触控板手势、麦克风、快捷键、应用启动和按键映射放在一个原生 SwiftUI 界面中。

## 功能

- 蓝牙或 USB 连接多个 DualSense，并显示电量和充电状态。
- 触控板支持移动鼠标、单击、双击、右键、拖拽、滚动和桌面切换手势。
- 支持键盘单键、鼠标单击/双击/长按/按住、快捷键组合和自定义组合键。
- 左右摇杆连续输出与实体按键可同时工作，适合拖拽和按住操作。
- 支持手柄麦克风，也支持选择其他 macOS 麦克风作为语音输入设备。
- 快捷轮盘可以启动 App、执行组合键宏或运行映射动作，支持手柄方向键和摇杆选择。
- 每个 App 可以使用独立映射，应用库支持从 Finder 直接拖入 `.app`。
- 支持浅色、深色和跟随系统外观。
- 映射冲突会在对应位置直接标记，窗口重新激活时会自动恢复。

## 系统要求

- macOS 14 或更高版本
- DualSense 手柄
- 使用鼠标、键盘、触控板或快捷键映射时，需要在系统设置中允许辅助功能和输入监控。
- 使用语音输入时，需要允许麦克风访问。

## 安装

从 GitHub Releases 下载 `DualVibe-Coding-*.dmg`，打开后将应用拖入 Applications。首次使用时，在“权限”页面打开 macOS 设置并完成授权，再返回应用点击“重新检查”。

## 从源码构建

```sh
brew install opus
./scripts/build-app.sh
./scripts/package-dmg.sh
```

构建脚本只会把构建产物放进本地 `.build/` 和 `dist/`，这些目录不会进入公开仓库。应用使用固定 Bundle Identifier 和持续签名身份，升级后 macOS 辅助功能授权可以继续复用。

## 界面预览

![按键映射](docs/screenshots/mapping.png)

![连接与语音](docs/screenshots/controller-voice.png)

![权限状态](docs/screenshots/permissions.png)

演示步骤见 [docs/DEMO.md](docs/DEMO.md)。

界面演示视频：[dualvibe-demo.mp4](docs/video/dualvibe-demo.mp4)

## 开源说明

仓库只包含源代码、构建脚本、必要的第三方声明和公开文档。个人映射、应用路径、签名密钥、构建缓存、历史截图和测试运行记录均被排除。

本项目参考并整合了 [Agent Remote](https://github.com/AbhisekBasu1/agent-remote) 的 DualSense 输入与触控板思路、[remote-mic-app](https://github.com/HD838A/remote-mic-app) 的麦克风方案，以及 [StarPie](https://github.com/Star-Pie/StarPie) 的手柄轮盘交互方式。

## 许可证

DualVibe Coding 使用 MIT License。第三方组件的许可证和声明随应用一起打包，并保存在 `ThirdParty/AgentRemote`。

## 交流群

欢迎加入 DualVibe Coding 交流群交流，遇到问题也可以在群里反馈。

![DualVibe Coding 交流群二维码](docs/community/dualvibe-coding-group.jpg)
