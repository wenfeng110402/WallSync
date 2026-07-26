import SwiftUI
import Network

/// 节点模式视图
struct NodeView: View {
    @StateObject private var discovery = BonjourDiscoveryService()
    @StateObject private var client = TCPClientManager()
    @StateObject private var udpSync = UDPSyncManager()
    @StateObject private var syncEngine = SyncEngine()
    @StateObject private var videoEngine = VideoEngine()
    @StateObject private var renderer = MetalRenderer()

    @State private var nodeID: String = "node_\(Int.random(in: 1000...9999))"
    @State private var controllerHost: String = ""
    @State private var controllerPort: UInt16 = 0
    @State private var autoConnect: Bool = true
    @State private var showPeersSheet: Bool = false
    @State private var peerPortOverrides: [String: String] = [:]
    @State private var isConnecting = false
    @State private var currentRegion: RegionAssignment?
    @State private var isFullScreen = false
    @State private var hasConnectedToController = false
    @State private var connectionError: String?
    @State private var discoveryLog: [String] = []

    var body: some View {
        ZStack {
            // Metal 渲染层（全屏）
            renderer.swiftUIView
                .ignoresSafeArea()
                .background(.black)

            // 状态覆盖层
            VStack {
                // 顶部状态栏
                topStatusBar

                Spacer()

                // 播放信息
                if videoEngine.state == .playing || videoEngine.state == .paused {
                    playbackOverlay
                }

                // 底部状态
                if !isFullScreen {
                    bottomStatusBar
                }
            }
        }
        .frame(minWidth: 800, minHeight: 500)
        .navigationTitle("WallSync — 节点模式")
        .onAppear {
            client.delegate = self
            discovery.onControllerFound = { host, port in
                guard !hasConnectedToController else { return }
                DispatchQueue.main.async {
                    controllerHost = host
                    controllerPort = port
                    if autoConnect {
                        hasConnectedToController = true
                        print("[Node] 自动连接主控: \(host):\(port)")
                        connectToController(host: host, port: port)
                    } else {
                        discoveryLog.append("发现主控 \(host):\(port)（自动连接已关闭）")
                    }
                }
            }
            print("[Node] 正在搜索设备...")
            discovery.start()
            try? udpSync.startListener()
        }
        .onDisappear {
            discovery.stop()
            client.disconnect()
            udpSync.stopListener()
            videoEngine.clear()
        }
        .onReceive(udpSync.$lastSyncSignal) { signal in
            processSyncSignal(signal)
        }
        .sheet(isPresented: $showPeersSheet) {
            NavigationView {
                List {
                    ForEach(discovery.peers) { peer in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(peer.deviceName)
                                    .font(.headline)
                                Spacer()
                                Text(peer.isController ? "主控" : "节点")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            HStack(spacing: 12) {
                                VStack(alignment: .leading) {
                                    Text("Host: \(peer.hostName ?? "-")")
                                        .font(.caption2)
                                    Text("IP: \(peer.ipAddress ?? "-")")
                                        .font(.caption2)
                                }

                                Spacer()

                                VStack(alignment: .trailing) {
                                    HStack {
                                        Text("端口:")
                                            .font(.caption2)
                                        let defaultPort = peer.tcpPort > 0 ? String(peer.tcpPort) : (peer.port > 0 ? String(peer.port) : "")
                                        TextField("port", text: Binding(
                                            get: { peerPortOverrides[peer.id] ?? defaultPort },
                                            set: { peerPortOverrides[peer.id] = $0 }
                                        ))
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 100)
                                    }

                                    Button("连接") {
                                        connectToPeer(peer)
                                        showPeersSheet = false
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                }
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }
                .navigationTitle("发现的设备")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { showPeersSheet = false }
                    }
                }
            }
        }
    }

    // MARK: - 顶部状态栏

    private var topStatusBar: some View {
        HStack {
            // 节点信息
            HStack(spacing: 8) {
                Image(systemName: "desktopcomputer")
                    .foregroundStyle(.blue)
                Text("节点: \(nodeID)")
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Spacer()

            // Bonjour 状态
            HStack(spacing: 4) {
                Circle()
                    .fill(discovery.isPublishing ? .green : .orange)
                    .frame(width: 6, height: 6)
                Text("Bonjour")
                    .font(.caption)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            // 连接状态
            HStack(spacing: 6) {
                Circle()
                    .fill(connectionColor)
                    .frame(width: 8, height: 8)

                Text(connectionStatusText)
                    .font(.caption)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            // 同步质量
            HStack(spacing: 4) {
                Image(systemName: syncIcon)
                    .foregroundStyle(syncColor)
                Text(syncEngine.syncQuality.rawValue)
                    .font(.caption)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            // 全屏切换
            Button {
                isFullScreen.toggle()
            } label: {
                Image(systemName: isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(12)
    }

    // MARK: - 播放覆盖层

    private var playbackOverlay: some View {
        VStack(spacing: 8) {
            // 帧率
            if renderer.frameRate > 0 {
                Text(String(format: "%.0f fps", renderer.frameRate))
                    .font(.system(size: 16, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.8))
            }

            // 播放时间
            if videoEngine.currentTime > 0 {
                Text(formatTime(videoEngine.currentTime))
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
            }

            // 区域信息
            if let region = currentRegion {
                Text("区域: (\(region.originX), \(region.originY)) \(region.width)×\(region.height)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.black.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.bottom, 40)
    }

    // MARK: - 底部状态栏

    private var bottomStatusBar: some View {
        VStack(spacing: 0) {
            // 连接错误提示
            if let error = connectionError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.yellow)
                    Spacer()
                    Button("重试") {
                        connectionError = nil
                        hasConnectedToController = false
                        // 重新搜索
                        discovery.stop()
                        discoveryLog.append("重新搜索...")
                        discovery.start()
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.white)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(.red.opacity(0.6))
            }

            HStack {
                Text("WallSync Node")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Spacer()

                Text("已发现 \(discovery.peers.count) 台设备")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button("管理设备") {
                    showPeersSheet = true
                }
                .font(.caption2)
                .padding(.leading, 6)

                if controllerPort > 0 {
                    Text("· 主控 \(controllerHost):\(controllerPort)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if let region = currentRegion {
                    Text("节点 #\(region.nodeIndex + 1) · \(region.width)×\(region.height)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if case .connected = client.connectionState {
                    Text("已注册")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }

                // 自动连接开关
                Toggle(isOn: $autoConnect) {
                    Text("自动连接")
                        .font(.caption2)
                }
                .toggleStyle(.switch)
                .frame(width: 120)

                Spacer()

                Text("同步延迟: \(String(format: "%.2f ms", syncEngine.estimatedLatency * 1000))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
        }
    }

    // MARK: - 连接控制

    private func connectToController(host: String, port: UInt16) {
        controllerHost = host
        controllerPort = port
        isConnecting = true
        connectionError = nil
        discoveryLog.append("连接主控 \(host):\(port)...")

        client.connect(to: host, port: port, nodeID: nodeID)
    }

    // 手动连接某个 peer，支持端口覆盖字符串
    private func connectToPeer(_ peer: WallSyncPeer) {
        guard let host = peer.ipAddress ?? peer.hostName else {
            connectionError = "无法解析主控地址"
            return
        }

        // 优先使用覆盖端口
        let override = peerPortOverrides[peer.id]
        let portToUse: UInt16
        if let ov = override, let p = UInt16(ov) {
            portToUse = p
        } else if peer.tcpPort > 0 {
            portToUse = peer.tcpPort
        } else if peer.port > 0 {
            portToUse = UInt16(peer.port)
        } else {
            connectionError = "未提供端口"
            return
        }

        hasConnectedToController = true
        connectToController(host: host, port: portToUse)
    }

    // MARK: - 同步信号处理

    private func processSyncSignal(_ signal: SyncSignal?) {
        guard let signal = signal else { return }

        let calibratedTime = syncEngine.processSyncSignal(signal)

        // 根据同步信号控制本地播放
        switch signal.state {
        case .playing:
            if videoEngine.state != .playing {
                videoEngine.play()
            }
        case .paused:
            if videoEngine.state == .playing {
                videoEngine.pause()
            }
        case .stopped:
            videoEngine.stop()
        }
    }

    // MARK: - 辅助

    private var connectionColor: Color {
        if connectionError != nil { return .red }
        switch client.connectionState {
        case .connected: return .green
        case .connecting: return .orange
        case .disconnected: return .red
        case .failed: return .red
        }
    }

    private var connectionStatusText: String {
        if let error = connectionError { return "失败: \(error)" }
        switch client.connectionState {
        case .connected: return "已连接主控"
        case .connecting: return "连接中..."
        case .disconnected: return "未连接"
        case .failed(let error): return "连接失败: \(error.localizedDescription)"
        }
    }

    private var syncIcon: String {
        switch syncEngine.syncQuality {
        case .unknown: return "antenna.radiowaves.left.and.right.slash"
        case .poor: return "exclamationmark.triangle"
        case .fair: return "wifi"
        case .good: return "wifi"
        case .excellent: return "wifi"
        }
    }

    private var syncColor: Color {
        switch syncEngine.syncQuality {
        case .unknown: return .gray
        case .poor: return .red
        case .fair: return .orange
        case .good: return .yellow
        case .excellent: return .green
        }
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let mins = Int(time) / 60
        let secs = Int(time) % 60
        let millis = Int((time - Double(Int(time))) * 1000)
        return String(format: "%02d:%02d.%03d", mins, secs, millis)
    }
}

// MARK: - TCP 客户端代理
extension NodeView: TCPConnectionDelegate {
    func connectionDidReceiveMessage(_ message: ControlMessage, from nodeID: String) {
        switch message.type {
        case .nodeRegistered:
            print("[Node] 已注册到主控")
            isConnecting = false
            connectionError = nil
            discoveryLog.append("已注册到主控")

        case .regionAssignment:
            if let payload = message.payload,
               let assignment = try? JSONDecoder().decode(RegionAssignment.self, from: payload) {
                currentRegion = assignment
                // 更新渲染区域
                let totalWidth: Float = 7680 // 需要从主控获取，这里用默认
                let totalHeight: Float = 2160
                renderer.updateRegion(
                    offsetX: Float(assignment.originX) / totalWidth,
                    offsetY: Float(assignment.originY) / totalHeight,
                    scaleX: Float(assignment.width) / totalWidth,
                    scaleY: Float(assignment.height) / totalHeight
                )
                print("[Node] 接收到区域分配: #\(assignment.nodeIndex)")
            }

        case .startPlayback:
            if let payload = message.payload,
               let info = try? JSONDecoder().decode(VideoInfoPayload.self, from: payload) {
                let url = URL(fileURLWithPath: info.filePath)
                Task {
                    try? await videoEngine.load(url: url)
                    videoEngine.onFrameDecoded = { [renderer] pixelBuffer, _ in
                        renderer.enqueuePixelBuffer(pixelBuffer)
                    }
                    videoEngine.play()
                }
            }

        case .pausePlayback:
            videoEngine.pause()

        case .stopPlayback:
            videoEngine.stop()

        case .seekTo:
            if let payload = message.payload,
               let dict = try? JSONDecoder().decode([String: Double].self, from: payload),
               let time = dict["time"] {
                videoEngine.seek(to: time)
            }

        case .heartbeatAck:
            break

        default:
            break
        }
    }

    func connectionStateDidChange(_ state: TCPConnectionState, for nodeID: String) {
        print("[Node] 连接状态: \(state)")
        if case .failed(let error) = state {
            connectionError = error.localizedDescription
            discoveryLog.append("连接失败: \(error.localizedDescription)")
        }
    }
}
