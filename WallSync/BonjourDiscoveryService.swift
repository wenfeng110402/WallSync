import Foundation
import Combine
import Darwin

@MainActor
final class BonjourDiscoveryService: NSObject, ObservableObject {
    static let serviceType = "_wallsync._tcp."
    static let serviceDomain = ""

    @Published private(set) var peers: [WallSyncPeer] = []
    @Published private(set) var isPublishing = false
    @Published private(set) var publishingError: String?
    @Published private(set) var foundControllerHost: String?
    @Published private(set) var foundControllerPort: UInt16 = 0

    /// 当发现主控时回调
    var onControllerFound: ((String, UInt16) -> Void)?

    let deviceID: String
    let deviceName: String
    let nodeNumber: Int

    private var isController = false
    private var controllerPort: UInt16 = 0

    private let browser = NetServiceBrowser()
    private var publishedService: NetService?
    /// 用自增 ID 跟踪尚未解析的服务，避免同名设备被跳过
    private var pendingResolveID = UInt64(0)
    private var pendingResolves: Set<String> = []

    init(
        deviceName: String = Host.current().localizedName ?? "WallSync Mac",
        nodeNumber: Int = 0
    ) {
        let savedID = UserDefaults.standard.string(forKey: "WallSync.deviceID")

        if let savedID, !savedID.isEmpty {
            self.deviceID = savedID
        } else {
            let newID = UUID().uuidString
            UserDefaults.standard.set(newID, forKey: "WallSync.deviceID")
            self.deviceID = newID
        }

        self.deviceName = deviceName
        self.nodeNumber = nodeNumber

        super.init()

        browser.delegate = self
    }

    func start() {
        stop()

        publishService()
        browser.searchForServices(
            ofType: Self.serviceType,
            inDomain: Self.serviceDomain
        )
    }

    /// 标记为主控模式
    func advertiseAsController(_ isController: Bool, port: UInt16 = 0) {
        self.isController = isController
        self.controllerPort = port
        // 如果已发布则重新发布以更新 TXT 记录
        if publishedService != nil {
            publishedService?.stop()
            publishedService = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.publishService()
            }
        }
    }

    /// 主控是否已标记
    var isAdvertisedAsController: Bool { isController }

    func stop() {
        browser.stop()
        publishedService?.stop()
        publishedService = nil
        isPublishing = false

        pendingResolves.removeAll()
        peers.removeAll()
    }

    private func publishService() {
        var txtRecord: [String: Data] = [
            "deviceID": Data(deviceID.utf8),
            "deviceName": Data(deviceName.utf8),
            "nodeNumber": Data(String(nodeNumber).utf8),
            "protocolVersion": Data("1".utf8)
        ]

        if isController {
            txtRecord["isController"] = Data("true".utf8)
            txtRecord["tcpPort"] = Data(String(controllerPort).utf8)
        }

        let service = NetService(
            domain: Self.serviceDomain,
            type: Self.serviceType,
            name: deviceName,
            port: 0
        )

        service.delegate = self
        service.setTXTRecord(NetService.data(fromTXTRecord: txtRecord))
        service.publish(options: [.listenForConnections])

        publishedService = service
    }

    private func addOrUpdatePeer(
        from service: NetService,
        status: WallSyncPeerStatus,
        ipAddress resolvedIPAddress: String? = nil
    ) {
        let txt = service.txtRecordData()
            .map(NetService.dictionary)
            ?? [:]

        let remoteDeviceID = stringValue(for: "deviceID", in: txt)
            ?? service.name

        guard remoteDeviceID != deviceID else {
            return
        }

        let remoteDeviceName = stringValue(for: "deviceName", in: txt)
            ?? service.name

        let remoteNodeNumber = Int(
            stringValue(for: "nodeNumber", in: txt) ?? ""
        )

        let isControllerPeer = stringValue(for: "isController", in: txt) == "true"
        let controllerTCPPort = UInt16(stringValue(for: "tcpPort", in: txt) ?? "") ?? 0

        // 如果发现主控且本机为节点模式，自动连接
        if isControllerPeer, let ip = resolvedIPAddress ?? self.ipAddress(from: service), controllerTCPPort > 0 {
            DispatchQueue.main.async {
                self.foundControllerHost = ip
                self.foundControllerPort = controllerTCPPort
                self.onControllerFound?(ip, controllerTCPPort)
            }
        }

        let peer = WallSyncPeer(
            id: remoteDeviceID,
            deviceName: remoteDeviceName,
            hostName: service.hostName,
            ipAddress: resolvedIPAddress,
            port: service.port,
            nodeNumber: remoteNodeNumber,
            status: status,
            isController: isControllerPeer,
            tcpPort: controllerTCPPort
        )

        if let index = peers.firstIndex(where: { $0.id == peer.id }) {
            peers[index] = peer
        } else {
            peers.append(peer)
        }

        peers.sort {
            ($0.nodeNumber ?? Int.max, $0.deviceName)
                < ($1.nodeNumber ?? Int.max, $1.deviceName)
        }
    }

    private func stringValue(
        for key: String,
        in record: [String: Data]
    ) -> String? {
        guard let data = record[key] else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    private func resolve(_ service: NetService) {
        // 使用内存地址 + 名称作为唯一标识，避免同名设备被跳过
        let resolveKey = "\(Unmanaged.passUnretained(service).toOpaque())|\(service.name)"

        guard !pendingResolves.contains(resolveKey) else {
            return
        }

        pendingResolves.insert(resolveKey)

        addOrUpdatePeer(
            from: service,
            status: .resolving
        )

        service.delegate = self
        service.resolve(withTimeout: 5.0)
    }

    private func ipAddress(from service: NetService) -> String? {
        guard let addresses = service.addresses else {
            return nil
        }

        // 优先选择 IPv4 地址，再回退到 IPv6
        let families: [Int32] = [AF_INET, AF_INET6]

        for family in families {
            for addressData in addresses {
                let result: String? = addressData.withUnsafeBytes { rawBuffer in
                    guard let baseAddress = rawBuffer.baseAddress else {
                        return nil
                    }

                    // 检查地址族
                    let sockaddrPtr = baseAddress.assumingMemoryBound(to: sockaddr.self)
                    let saFamily = Int32(sockaddrPtr.pointee.sa_family)
                    guard saFamily == family else { return nil }

                    let storage = baseAddress.assumingMemoryBound(to: sockaddr_storage.self)

                    var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))

                    let result = getnameinfo(
                        UnsafePointer<sockaddr>(OpaquePointer(storage)),
                        socklen_t(addressData.count),
                        &hostBuffer,
                        socklen_t(hostBuffer.count),
                        nil,
                        0,
                        NI_NUMERICHOST
                    )

                    guard result == 0 else {
                        return nil
                    }

                    return String(cString: hostBuffer)
                }

                if let result {
                    return result
                }
            }
        }

        return nil
    }
}

extension BonjourDiscoveryService: NetServiceBrowserDelegate {
    nonisolated func netServiceBrowserWillSearch(
        _ browser: NetServiceBrowser
    ) {
        // Discovery has started.
    }

    nonisolated func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.resolve(service)
        }
    }

    nonisolated func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didRemove service: NetService,
        moreComing: Bool
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }

            let resolveKey = "\(Unmanaged.passUnretained(service).toOpaque())|\(service.name)"
            self.pendingResolves.remove(resolveKey)

            let txt = service.txtRecordData()
                .map(NetService.dictionary)
                ?? [:]

            let remoteDeviceID = self.stringValue(
                for: "deviceID",
                in: txt
            ) ?? service.name

            self.peers.removeAll { $0.id == remoteDeviceID }
        }
    }

    nonisolated func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didNotSearch errorDict: [String: NSNumber]
    ) {
        // Search errors can be surfaced in the later error-handling phase.
    }
}

extension BonjourDiscoveryService: NetServiceDelegate {
    nonisolated func netServiceDidPublish(_ sender: NetService) {
        Task { @MainActor [weak self] in
            self?.isPublishing = true
            self?.publishingError = nil
        }
    }

    nonisolated func netService(
        _ sender: NetService,
        didNotPublish errorDict: [String: NSNumber]
    ) {
        Task { @MainActor [weak self] in
            self?.isPublishing = false
            self?.publishingError = errorDict
                .map { "\($0.key): \($0.value)" }
                .joined(separator: ", ")
        }
    }

    nonisolated func netServiceDidResolveAddress(
        _ sender: NetService
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }

            self.addOrUpdatePeer(
                from: sender,
                status: .online,
                ipAddress: self.ipAddress(from: sender)
            )
        }
    }

    nonisolated func netService(
        _ sender: NetService,
        didNotResolve errorDict: [String: NSNumber]
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }

            self.addOrUpdatePeer(
                from: sender,
                status: .discovered
            )
        }
    }
}
