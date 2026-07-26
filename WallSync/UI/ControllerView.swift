import SwiftUI
import UniformTypeIdentifiers

/// 主控模式视图
struct ControllerView: View {
    @StateObject private var discovery = BonjourDiscoveryService()
    @StateObject private var server = TCPServerManager()
    @StateObject private var udpSync = UDPSyncManager()
    @StateObject private var syncEngine = SyncEngine()
    @StateObject private var videoEngine = VideoEngine()
    @StateObject private var renderer = MetalRenderer()

    @State private var selectedLayout: WallLayoutConfig = .preset3x1
    @State private var isPlaying = false
    @State private var isPaused = false
    @State private var selectedVideoURL: URL?
    @State private var showFilePicker = false
    @State private var isShowingNodeRegions = true
    @State private var customPortText: String = ""
    @State private var portNotice: String?
    @State private var nodeOrder: [String] = []

    private static let customPortKey = "WallSync.customTCPPort"

    var body: some View {
        NavigationSplitView {
            deviceListSidebar
                .frame(minWidth: 260)
        } detail: {
            HStack(spacing: 0) {
                videoWallArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                controlPanel
                    .frame(width: 300)
            }
        }
        .navigationTitle("WallSync — 主控模式")
        .frame(minWidth: 1_200, minHeight: 700)
        .onAppear {
            server.delegate = self
            // 先启动 TCP 服务器获取真实端口，再发布 Bonjour
            server.onReady = { [self] port in
                discovery.advertiseAsController(true, port: port)
                discovery.start()
            }
            let savedPort = UInt16(exactly: UserDefaults.standard.integer(forKey: Self.customPortKey)) ?? 0
            customPortText = savedPort > 0 ? String(savedPort) : ""
            startServer(port: savedPort)
        }
        .onDisappear {
            discovery.stop()
            server.stop()
            udpSync.stopListener()
            videoEngine.clear()
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.movie, .video, UTType("com.apple.quicktime-movie")].compactMap { $0 },
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                loadVideo(url: url)
            }
        }
    }

    // MARK: - 设备列表侧边栏

    private var deviceListSidebar: some View {
        List {
            Section("主控 (本机)") {
                HStack(spacing: 10) {
                    Image(systemName: "rectangle.3.group.fill")
                        .foregroundStyle(.blue)
                        .font(.title3)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(discovery.deviceName)
                            .font(.headline)
                        Text("主控 · 端口 \(server.port ?? 0)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                }
                .padding(.vertical, 4)
            }

            Section("已连接节点 (\(server.connections.count))") {
                if server.connections.isEmpty {
                    ContentUnavailableView(
                        "等待节点连接",
                        systemImage: "wifi.slash",
                        description: Text("启动其他 Mac 上的 WallSync 节点模式")
                    )
                } else {
                    ForEach(Array(server.connections.keys), id: \.self) { nodeID in
                        HStack(spacing: 10) {
                            Image(systemName: "desktopcomputer")
                                .foregroundStyle(.green)

                            VStack(alignment: .leading, spacing: 3) {
                                Text("节点 \(nodeID)")
                                    .font(.subheadline)
                                Text("已连接")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            Section("已发现设备 (\(discovery.peers.count))") {
                if discovery.peers.isEmpty {
                    Text("未发现其他设备")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                } else {
                    ForEach(discovery.peers) { peer in
                        HStack(spacing: 8) {
                            Image(systemName: "desktopcomputer")
                                .foregroundStyle(peer.status == .online ? .green : .orange)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(peer.deviceName)
                                    .lineLimit(1)
                                Text(peer.ipAddress ?? "未知")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Text(peer.status.rawValue)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - 视频墙区域

    private var videoWallArea: some View {
        VStack(spacing: 0) {
            // 视频渲染区域
            if videoEngine.state == .ready || videoEngine.state == .playing || videoEngine.state == .paused {
                renderer.swiftUIView
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
                    .padding(12)
                    .overlay(alignment: .topTrailing) {
                        if videoEngine.state == .playing || videoEngine.state == .paused {
                            HStack(spacing: 12) {
                                // 节点区域网格叠加
                                if isShowingNodeRegions {
                                    nodeRegionOverlay
                                }

                                // 状态信息
                                HStack(spacing: 16) {
                                    Label(videoEngine.frameRate > 0 ?
                                        String(format: "%.1f fps", videoEngine.frameRate) : "-- fps",
                                          systemImage: "play.display")
                                    Label(formatTime(videoEngine.currentTime),
                                          systemImage: "clock")
                                }
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(.ultraThinMaterial)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .padding(16)
                            }
                        }
                    }
            } else {
                // 空状态
                VStack(spacing: 16) {
                    Image(systemName: "rectangle.on.rectangle.angled")
                        .font(.system(size: 56))
                        .foregroundStyle(.secondary)

                    Text("视频墙预览")
                        .font(.title2)
                        .fontWeight(.semibold)

                    if videoEngine.state == .loading {
                        ProgressView("加载视频中...")
                    } else {
                        Text("选择视频文件开始")
                            .foregroundStyle(.secondary)

                        Button("选择视频") {
                            showFilePicker = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
    }

    /// 节点区域网格叠加层
    private var nodeRegionOverlay: some View {
        GeometryReader { geo in
            let cols = selectedLayout.columns
            let rows = selectedLayout.rows
            let cellW = geo.size.width / CGFloat(cols)
            let cellH = geo.size.height / CGFloat(rows)

            ZStack {
                // 网格线
                ForEach(0..<cols, id: \.self) { col in
                    Rectangle()
                        .fill(Color.blue.opacity(0.15))
                        .frame(width: cellW)
                        .position(x: cellW * CGFloat(col) + cellW / 2, y: geo.size.height / 2)
                        .overlay(
                            Rectangle()
                                .stroke(Color.blue.opacity(0.4), lineWidth: 0.5)
                        )
                }

                ForEach(0..<rows, id: \.self) { row in
                    Rectangle()
                        .fill(Color.blue.opacity(0.15))
                        .frame(height: cellH)
                        .position(x: geo.size.width / 2, y: cellH * CGFloat(row) + cellH / 2)
                        .overlay(
                            Rectangle()
                                .stroke(Color.blue.opacity(0.4), lineWidth: 0.5)
                        )
                }

                // 节点编号
                ForEach(0..<min(selectedLayout.totalNodes, 10), id: \.self) { idx in
                    let col = idx % cols
                    let row = idx / cols
                    Text("Node \(idx + 1)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.blue.opacity(0.7))
                        .position(
                            x: cellW * CGFloat(col) + cellW / 2,
                            y: cellH * CGFloat(row) + cellH / 2
                        )
                }
            }
            .allowsHitTesting(false)
        }
        .allowsHitTesting(false)
    }

    // MARK: - 控制面板

    private var controlPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 标题
            HStack {
                Image(systemName: "slider.horizontal.3")
                    .font(.title3)
                Text("控制面板")
                    .font(.title3)
                    .fontWeight(.semibold)
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // 视频选择
                    videoSection

                    // 布局设置
                    layoutSection

                    // 网络设置
                    networkSection

                    // 播放控制
                    playbackSection

                    // 同步信息
                    syncSection

                    // 操作日志
                    logSection
                }
            }
        }
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private var videoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("视频源", systemImage: "film")

            if let url = selectedVideoURL {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(url.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption)

                HStack {
                    Text("\(Int(videoEngine.duration))秒")
                    if videoEngine.naturalSize.width > 0 {
                        Text("· \(Int(videoEngine.naturalSize.width))×\(Int(videoEngine.naturalSize.height))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Button(selectedVideoURL == nil ? "选择视频" : "更换视频") {
                showFilePicker = true
            }
            .buttonStyle(.bordered)
            .font(.caption)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var layoutSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("视频墙布局", systemImage: "grid")

            Picker("布局", selection: $selectedLayout) {
                ForEach(WallLayoutConfig.allPresets) { layout in
                    Text("\(layout.columns)×\(layout.rows) (\(layout.totalNodes) 节点)")
                        .tag(layout)
                }
            }
            .pickerStyle(.menu)

            if !server.connections.isEmpty {
                HStack {
                    Text("已连接 \(server.connections.count)/\(selectedLayout.totalNodes) 节点")
                        .font(.caption)
                        .foregroundStyle(server.connections.count >= selectedLayout.totalNodes ? .green : .orange)

                    if server.connections.count >= selectedLayout.totalNodes {
                        Button("应用布局") {
                            applyLayout()
                        }
                        .buttonStyle(.borderedProminent)
                        .font(.caption)
                    }
                }

                // 节点排序：序号 1 对应左上角，按行优先排列
                VStack(alignment: .leading, spacing: 4) {
                    Text("显示器顺序（1 = 左上）")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(Array(orderedNodeIDs.enumerated()), id: \.element) { index, nodeID in
                        HStack(spacing: 6) {
                            Text("#\(index + 1)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.blue)
                                .frame(width: 24, alignment: .leading)

                            Text(nodeID)
                                .font(.caption)
                                .lineLimit(1)

                            Spacer()

                            Button {
                                moveNode(at: index, offset: -1)
                            } label: {
                                Image(systemName: "chevron.up")
                            }
                            .buttonStyle(.borderless)
                            .disabled(index == 0)

                            Button {
                                moveNode(at: index, offset: 1)
                            } label: {
                                Image(systemName: "chevron.down")
                            }
                            .buttonStyle(.borderless)
                            .disabled(index == orderedNodeIDs.count - 1)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            Toggle(isOn: $isShowingNodeRegions) {
                Text("显示节点区域划分")
                    .font(.caption)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var networkSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("网络设置", systemImage: "network")

            HStack {
                Text("TCP 端口:")
                    .font(.caption)
                TextField("自动", text: $customPortText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .onSubmit { applyCustomPort() }
                Button("应用") {
                    applyCustomPort()
                }
                .buttonStyle(.bordered)
                .font(.caption)
            }

            Text("当前端口: \(server.port.map(String.init) ?? "未启动") · 留空为自动分配")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if let notice = portNotice {
                Text(notice)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var playbackSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("播放控制", systemImage: "play.rectangle")

            // 进度条
            if videoEngine.duration > 0 {
                VStack(spacing: 4) {
                    Slider(
                        value: Binding(
                            get: { videoEngine.currentTime },
                            set: { newTime in
                                videoEngine.seek(to: newTime)
                                // 通知所有节点 seek
                                let seekMsg = ControlMessage(
                                    type: .seekTo,
                                    payload: try? JSONEncoder().encode(["time": newTime])
                                )
                                server.broadcast(seekMsg)
                            }
                        ),
                        in: 0...videoEngine.duration
                    )
                    .disabled(videoEngine.state != .ready &&
                              videoEngine.state != .playing &&
                              videoEngine.state != .paused)

                    HStack {
                        Text(formatTime(videoEngine.currentTime))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(formatTime(videoEngine.duration))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // 播放按钮
            HStack(spacing: 12) {
                Button {
                    if isPlaying {
                        pausePlayback()
                    } else {
                        startPlayback()
                    }
                } label: {
                    Label(isPlaying && !isPaused ? "暂停" : "播放",
                          systemImage: isPlaying && !isPaused ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(videoEngine.state != .ready &&
                          videoEngine.state != .playing &&
                          videoEngine.state != .paused)

                Button {
                    stopPlayback()
                } label: {
                    Label("停止", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .disabled(videoEngine.state != .playing && videoEngine.state != .paused)

                Spacer()
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var syncSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("同步状态", systemImage: "antenna.radiowaves.left.and.right")

            HStack {
                Text("质量:")
                    .font(.caption)
                Text(syncEngine.syncQuality.rawValue)
                    .font(.caption)
                    .foregroundStyle(syncColor(syncEngine.syncQuality))
            }

            HStack {
                Text("延迟:")
                    .font(.caption)
                Text(String(format: "%.2f ms", syncEngine.estimatedLatency * 1000))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("信号计数:")
                    .font(.caption)
                Text("\(udpSync.syncSignalCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("系统信息", systemImage: "info.circle")

            Group {
                Text("Bonjour: \(discovery.isPublishing ? "已发布" : "启动中")")
                Text("TCP 端口: \(server.port ?? 0)")
                Text("UDP 端口: \(udpSync.listenerPort ?? 5321)")
                Text("视频引擎: \(videoEngine.state.description)")
                Text("Metal 设备: \(renderer.device.name)")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - 服务器启动

    /// 启动 TCP 服务器；自定义端口失败时回退到系统自动分配
    private func startServer(port: UInt16) {
        server.onFailed = { [self] error in
            guard port > 0 else { return }
            print("[Controller] 端口 \(port) 启动失败: \(error)，回退自动分配")
            portNotice = "端口 \(port) 不可用，已回退自动分配"
            server.stop()
            startServer(port: 0)
        }

        do {
            try server.start(port: port)
            if port > 0 { portNotice = nil }
        } catch {
            print("[Controller] TCP 服务启动失败: \(error)")
            if port > 0 {
                portNotice = "端口 \(port) 不可用，已回退自动分配"
                startServer(port: 0)
            }
        }
    }

    private func applyCustomPort() {
        let trimmed = customPortText.trimmingCharacters(in: .whitespaces)
        let port: UInt16
        if trimmed.isEmpty {
            port = 0
        } else if let p = UInt16(trimmed), p > 0 {
            port = p
        } else {
            portNotice = "无效端口（1-65535，留空为自动）"
            return
        }

        UserDefaults.standard.set(Int(port), forKey: Self.customPortKey)
        portNotice = nil
        discovery.stop()
        server.stop()
        startServer(port: port)
    }

    // MARK: - 播放控制方法

    private func loadVideo(url: URL) {
        selectedVideoURL = url
        Task {
            do {
                try await videoEngine.load(url: url)
                videoEngine.onFrameDecoded = { [renderer] pixelBuffer, _ in
                    renderer.enqueuePixelBuffer(pixelBuffer)
                }
            } catch {
                print("[Controller] 视频加载失败: \(error)")
            }
        }
    }

    private func startPlayback() {
        guard videoEngine.state == .ready || videoEngine.state == .paused else { return }

        videoEngine.play()
        isPlaying = true
        isPaused = false

        // 广播播放指令
        let msg = ControlMessage(
            type: .startPlayback,
            payload: try? JSONEncoder().encode(VideoInfoPayload(
                filePath: selectedVideoURL?.path ?? "",
                duration: videoEngine.duration,
                naturalWidth: Int(videoEngine.naturalSize.width),
                naturalHeight: Int(videoEngine.naturalSize.height),
                videoID: UUID().uuidString
            ))
        )
        server.broadcast(msg)

        // 开始 UDP 同步
        startSyncBroadcast()
    }

    private func pausePlayback() {
        videoEngine.pause()
        isPaused = true

        let msg = ControlMessage(type: .pausePlayback)
        server.broadcast(msg)
    }

    private func stopPlayback() {
        videoEngine.stop()
        isPlaying = false
        isPaused = false

        let msg = ControlMessage(type: .stopPlayback)
        server.broadcast(msg)
    }

    /// 按用户排序返回已连接节点，未手动排过序的按 ID 排在末尾
    private var orderedNodeIDs: [String] {
        let connected = Set(server.connections.keys)
        var result = nodeOrder.filter { connected.contains($0) }
        let remaining = connected.subtracting(result).sorted()
        result.append(contentsOf: remaining)
        return result
    }

    private func moveNode(at index: Int, offset: Int) {
        var order = orderedNodeIDs
        let target = index + offset
        guard order.indices.contains(index), order.indices.contains(target) else { return }
        order.swapAt(index, target)
        nodeOrder = order
    }

    private func applyLayout() {
        let cols = selectedLayout.columns
        let videoW = max(Int(videoEngine.naturalSize.width), 1920)
        let videoH = max(Int(videoEngine.naturalSize.height), 1080)
        let cellW = videoW / cols

        let nodeIDs = orderedNodeIDs

        for (index, nodeID) in nodeIDs.prefix(selectedLayout.totalNodes).enumerated() {
            let assignment = RegionAssignment(
                nodeID: nodeID,
                nodeIndex: index,
                originX: (index % cols) * cellW,
                originY: (index / cols) * (videoH / selectedLayout.rows),
                width: cellW,
                height: videoH / selectedLayout.rows
            )

            let msg = ControlMessage(
                type: .regionAssignment,
                payload: try? JSONEncoder().encode(assignment)
            )
            server.send(to: nodeID, msg)
        }

        renderer.updateRegion(offsetX: 0, offsetY: 0, scaleX: 1, scaleY: 1)
    }

    private func startSyncBroadcast() {
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { timer in
            guard isPlaying else {
                timer.invalidate()
                return
            }

            let state: SyncSignal.PlaybackState = isPaused ? .paused : .playing
            udpSync.broadcastSync(
                presentationTime: videoEngine.currentTime,
                rate: 1.0,
                state: state
            )
        }
    }

    // MARK: - 辅助

    private func formatTime(_ time: TimeInterval) -> String {
        let mins = Int(time) / 60
        let secs = Int(time) % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    private func syncColor(_ quality: SyncEngine.SyncQuality) -> Color {
        switch quality {
        case .unknown: return .gray
        case .poor: return .red
        case .fair: return .orange
        case .good: return .yellow
        case .excellent: return .green
        }
    }
}

// MARK: - TCP 服务器代理
extension ControllerView: TCPConnectionDelegate {
    func connectionDidReceiveMessage(_ message: ControlMessage, from nodeID: String) {
        switch message.type {
        case .registerNode:
            let response = ControlMessage(type: .nodeRegistered)
            server.send(to: nodeID, response)
            print("[Controller] 节点已注册: \(nodeID)")
        case .heartbeat:
            let ack = ControlMessage(type: .heartbeatAck)
            server.send(to: nodeID, ack)
        default:
            break
        }
    }

    func connectionStateDidChange(_ state: TCPConnectionState, for nodeID: String) {
        print("[Controller] 节点 \(nodeID) 状态: \(state)")
    }
}

// MARK: - 状态描述
extension VideoEngineState: CustomStringConvertible {
    var description: String {
        switch self {
        case .idle: return "空闲"
        case .loading: return "加载中"
        case .ready: return "就绪"
        case .playing: return "播放中"
        case .paused: return "已暂停"
        case .stopped: return "已停止"
        case .failed(let error): return "错误: \(error.localizedDescription)"
        }
    }
}
