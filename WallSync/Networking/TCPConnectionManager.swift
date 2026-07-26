import Foundation
import Combine
import Network

// MARK: - TCP 连接管理器
// 同时支持 Server（主控）和 Client（节点）模式

/// TCP 连接状态
enum TCPConnectionState {
    case disconnected
    case connecting
    case connected
    case failed(Error)
}

/// 连接事件回调
protocol TCPConnectionDelegate {
    func connectionDidReceiveMessage(_ message: ControlMessage, from nodeID: String)
    func connectionStateDidChange(_ state: TCPConnectionState, for nodeID: String)
}

/// 主控端 TCP Server
final class TCPServerManager: ObservableObject {
    @Published private(set) var connections: [String: TCPConnection] = [:]
    @Published private(set) var serverState: TCPConnectionState = .disconnected
    /// 服务器就绪后回调，传入真实端口号
    var onReady: ((UInt16) -> Void)?
    /// 服务器启动失败回调（如端口被占用）
    var onFailed: ((Error) -> Void)?

    private var listener: NWListener?
    private var backgroundQueue = DispatchQueue(label: "com.wallsync.tcp.server", qos: .userInitiated)
    var delegate: TCPConnectionDelegate?

    private var nextNodeIndex: Int = 0

    func start(port: UInt16 = 0) throws {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 2
        tcpOptions.keepaliveInterval = 2

        let params = NWParameters(tls: nil, tcp: tcpOptions)
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = true

        // port=0 表示让系统自动分配
        let resolvedPort: NWEndpoint.Port
        if let p = NWEndpoint.Port(rawValue: port), port > 0 {
            resolvedPort = p
        } else {
            // 使用 .any 让系统自动分配可用端口
            resolvedPort = .any
        }

        listener = try NWListener(
            using: params,
            on: resolvedPort
        )

        listener?.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    let port = self?.listener?.port?.rawValue ?? 0
                    print("[TCP Server] 已启动，端口: \(port)")
                    UserDefaults.standard.set(port, forKey: "WallSync.tcpPort")
                    self?.serverState = .connected
                    if port > 0 {
                        self?.onReady?(port)
                    }
                case .failed(let error):
                    self?.serverState = .failed(error)
                    self?.onFailed?(error)
                case .cancelled:
                    self?.serverState = .disconnected
                default:
                    break
                }
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            guard let self = self else { return }
            let tcpConn = TCPConnection(connection: connection)
            let nodeID = "node_\(self.nextNodeIndex)"
            self.nextNodeIndex += 1

            connection.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    switch state {
                    case .ready:
                        self?.connections[nodeID] = tcpConn
                        self?.delegate?.connectionStateDidChange(.connected, for: nodeID)
                    case .failed(let error):
                        self?.connections.removeValue(forKey: nodeID)
                        self?.delegate?.connectionStateDidChange(.failed(error), for: nodeID)
                    case .cancelled:
                        self?.connections.removeValue(forKey: nodeID)
                        self?.delegate?.connectionStateDidChange(.disconnected, for: nodeID)
                    default:
                        break
                    }
                }
            }

            tcpConn.start(queue: self.backgroundQueue, receiveHandler: { [weak self] message in
                DispatchQueue.main.async {
                    self?.delegate?.connectionDidReceiveMessage(message, from: nodeID)
                }
            })
        }

        listener?.start(queue: backgroundQueue)
    }

    func stop() {
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        listener?.cancel()
        listener = nil
        DispatchQueue.main.async {
            self.serverState = .disconnected
        }
    }

    func broadcast(_ message: ControlMessage) {
        guard let data = message.encoded() else { return }
        connections.values.forEach { $0.send(data) }
    }

    func send(to nodeID: String, _ message: ControlMessage) {
        guard let conn = connections[nodeID], let data = message.encoded() else { return }
        conn.send(data)
    }

    var port: UInt16? {
        listener?.port?.rawValue
    }
}

/// 节点端 TCP Client
final class TCPClientManager: ObservableObject {
    @Published private(set) var connectionState: TCPConnectionState = .disconnected
    @Published private(set) var nodeID: String?

    private var connection: NWConnection?
    private var backgroundQueue = DispatchQueue(label: "com.wallsync.tcp.client", qos: .userInitiated)
    var delegate: TCPConnectionDelegate?
    private var recvBuffer = Data()

    func connect(to host: String, port: UInt16, nodeID: String) {
        self.nodeID = nodeID
        disconnect()

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 2

        let params = NWParameters(tls: nil, tcp: tcpOptions)
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = true

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? 0
        )

        connection = NWConnection(to: endpoint, using: params)

        connection?.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    self?.connectionState = .connected
                    self?.delegate?.connectionStateDidChange(.connected, for: nodeID)
                    // 连接就绪后开始接收并发送注册消息
                    self?.receiveMessages()
                    let regMsg = ControlMessage(
                        type: .registerNode,
                        payload: try? JSONEncoder().encode(["nodeID": nodeID]),
                        sequenceNumber: 0
                    )
                    if let data = regMsg.encoded() {
                        self?.connection?.send(content: data, completion: .contentProcessed({ _ in }))
                    }
                case .failed(let error):
                    self?.connectionState = .failed(error)
                    self?.delegate?.connectionStateDidChange(.failed(error), for: nodeID)
                case .cancelled:
                    self?.connectionState = .disconnected
                    self?.delegate?.connectionStateDidChange(.disconnected, for: nodeID)
                default:
                    break
                }
            }
        }

        connection?.start(queue: backgroundQueue)
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        DispatchQueue.main.async {
            self.connectionState = .disconnected
        }
    }

    func send(_ message: ControlMessage) {
        guard let data = message.encoded() else { return }
        connection?.send(content: data, completion: .contentProcessed({ _ in }))
    }

    private func receiveMessages() {
        connection?.receive(minimumIncompleteLength: 4, maximumLength: 1024 * 1024) { [weak self] content, _, isComplete, error in
            guard let self = self else { return }

            if let error = error {
                print("[TCP Client] 接收提示: \(error.localizedDescription)")
                // 错误不停止接收，继续监听
            }

            if let content = content, !content.isEmpty {
                // 累积缓冲，避免 TCP 分包/粘包导致消息边界丢失
                self.recvBuffer.append(content)

                while true {
                    if let (message, consumed) = ControlMessage.decode(from: self.recvBuffer) {
                        // 移除已消费的字节
                        self.recvBuffer.removeFirst(consumed)
                        DispatchQueue.main.async {
                            self.delegate?.connectionDidReceiveMessage(message, from: self.nodeID ?? "")
                        }
                    } else {
                        break
                    }
                }
            }

            if isComplete {
                DispatchQueue.main.async {
                    self.connectionState = .disconnected
                }
            } else {
                self.receiveMessages()
            }
        }
    }
}

// MARK: - TCP 连接封装

final class TCPConnection {
    private let connection: NWConnection
    private var recvBuffer = Data()

    init(connection: NWConnection) {
        self.connection = connection
    }

    func start(queue: DispatchQueue, receiveHandler: @escaping (ControlMessage) -> Void) {
        connection.start(queue: queue)
        receiveMessages(receiveHandler)
    }

    func send(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed({ _ in }))
    }

    func cancel() {
        connection.cancel()
    }

    private func receiveMessages(_ handler: @escaping (ControlMessage) -> Void) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 1024 * 1024) { [weak self] content, _, isComplete, error in
            guard let self = self else { return }

            if let error = error {
                print("[TCP Connection] 提示: \(error.localizedDescription)")
            }

            if let content = content, !content.isEmpty {
                // 累积缓冲，避免 TCP 分包/粘包导致消息边界丢失
                self.recvBuffer.append(content)

                while true {
                    if let (message, consumed) = ControlMessage.decode(from: self.recvBuffer) {
                        self.recvBuffer.removeFirst(consumed)
                        handler(message)
                    } else {
                        break
                    }
                }
            }

            if isComplete {
                print("[TCP Connection] 连接关闭")
            } else {
                self.receiveMessages(handler)
            }
        }
    }
}
