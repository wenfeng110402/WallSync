WallSync
=======

**WallSync** 是一个基于 macOS 的本地网络视频墙同步项目，使用 Bonjour 发现设备并通过 TCP/UDP 协议进行控制与同步。

**特性**
- **自动发现**：通过 Bonjour (`_wallsync._tcp.`) 浏览与发布设备。
- **可靠控制消息**：长度前缀 JSON 消息（已修复分包与对齐问题）。
- **低延迟同步**：使用 UDP 广播低延迟播放同步信号。

**快速开始**

- **需求**：macOS, Xcode 14+，Swift 工具链。
- **构建（命令行）**：

```bash
xcodebuild -project WallSync.xcodeproj -scheme WallSync -configuration Debug -sdk macosx CODE_SIGNING_ALLOWED=NO build
```

- **在 Xcode 中运行**：打开工程 `WallSync.xcodeproj`，选中 `WallSync` scheme，运行应用。运行时 macOS 会提示“本地网络”权限（如果未弹出，请检查 Info.plist 与 entitlements）。

**重要配置**
- **Info.plist**：需要包含 `NSLocalNetworkUsageDescription` 和 `NSBonjourServices`（包含 `_wallsync._tcp.`）。
- **权限（沙盒）**：项目包含 `WallSync.entitlements`，请确保在 Xcode 的 Build Settings 中将 `CODE_SIGN_ENTITLEMENTS` 指向它以在沙盒下允许本地网络访问（在开发时可用 `CODE_SIGNING_ALLOWED=NO` 跳过签名）。

**调试与测试**
- 启动一台作为 Controller（主控），确认应用在网络上发布服务并打印 TCP 端口。
- 启动另一台作为 Node（节点），观察是否在 UI 中发现 Controller 并能建立 TCP 连接。
- 已实现的健壮性修复：
  - TCP 接收已使用累积缓冲（处理分包/黏包）。
  - ControlMessage 的长度前缀读取已改为对齐安全的字节读取（避免 ARM 未对齐访问问题）。
  - Bonjour 解析优先选择 IPv4 地址以提升连通性成功率。

**目录结构（高层）**
- `WallSync/` — 应用源代码（包含 `Networking`, `Models`, `UI`, `VideoEngine` 等子目录）
- `WallSync.xcodeproj` — Xcode 工程文件

**问题与改进方向**
- 自动重连与退避策略（可选）：当前为手动重试或简单状态更新。
- 更严格的 IPv6 支持（zone id / link-local 处理）与多接口选择策略。

**许可证**
- 本项目采用 MIT 许可证，详见 `LICENSE`。

欢迎在本仓库基础上改进功能或提交 Issues/PR。
