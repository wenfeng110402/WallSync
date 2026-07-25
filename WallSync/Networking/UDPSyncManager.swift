import Foundation
import Combine
import Network

/// UDP 同步管理器
/// 主控：广播同步信号
/// 节点：接收同步信号
final class UDPSyncManager: ObservableObject {
    @Published private(set) var lastSyncSignal: SyncSignal?
    @Published private(set) var syncSignalCount: UInt64 = 0

    private var listener: NWListener?
    private var broadcastConnection: NWConnection?
    private let backgroundQueue = DispatchQueue(label: "com.wallsync.udp", qos: .userInteractive)
    private var sequenceNumber: UInt64 = 0

    /// 启动 UDP 监听（节点模式）
    func startListener(port: UInt16 = 5321) throws {
        let udpOptions = NWProtocolUDP.Options()
        let params = NWParameters(dtls: nil, udp: udpOptions)
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = true

        listener = try NWListener(
            using: params,
            on: NWEndpoint.Port(rawValue: port) ?? .any
        )

        listener?.newConnectionHandler = { [weak self] connection in
            connection.start(queue: self?.backgroundQueue ?? .main)
            self?.receiveSyncSignals(on: connection)
        }

        listener?.start(queue: backgroundQueue)
        print("[UDP] 监听器已启动，端口: \(port)")
    }

    /// 停止监听
    func stopListener() {
        listener?.cancel()
        listener = nil
    }

    /// 广播同步信号（主控模式）
    func broadcastSync(presentationTime: TimeInterval, rate: Float, state: SyncSignal.PlaybackState) {
        sequenceNumber += 1
        let signal = SyncSignal(
            presentationTime: presentationTime,
            sequenceNumber: sequenceNumber,
            rate: rate,
            state: state
        )

        guard let data = signal.encoded() else { return }

        // 创建临时 UDP 连接用于广播
        let udpOptions = NWProtocolUDP.Options()
        let params = NWParameters(dtls: nil, udp: udpOptions)
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = true

        // 尝试多个广播地址
        let broadcastAddresses = ["255.255.255.255", "239.255.0.1"]

        for addr in broadcastAddresses {
            let endpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(addr),
                port: NWEndpoint.Port(rawValue: 5321) ?? 5321
            )
            let conn = NWConnection(to: endpoint, using: params)
            conn.start(queue: backgroundQueue)
            conn.send(content: data, completion: .contentProcessed({ error in
                if let error = error {
                    print("[UDP] 广播发送失败: \(error)")
                }
                conn.cancel()
            }))
        }

        DispatchQueue.main.async {
            self.lastSyncSignal = signal
            self.syncSignalCount += 1
        }
    }

    /// 接收同步信号
    private func receiveSyncSignals(on connection: NWConnection) {
        connection.receiveMessage { [weak self] content, _, isComplete, error in
            if let error = error {
                print("[UDP] 接收错误: \(error)")
                return
            }

            if let content = content, let signal = SyncSignal.decode(from: content) {
                DispatchQueue.main.async {
                    self?.lastSyncSignal = signal
                    self?.syncSignalCount += 1
                }
            }

            if !isComplete {
                self?.receiveSyncSignals(on: connection)
            }
        }
    }

    /// 获取当前监听端口
    var listenerPort: UInt16? {
        listener?.port?.rawValue
    }

    deinit {
        stopListener()
    }
}
