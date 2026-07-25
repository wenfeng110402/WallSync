import Foundation

enum WallSyncPeerStatus: String {
    case discovered = "已发现"
    case resolving = "解析中"
    case online = "在线"
    case offline = "离线"
}

struct WallSyncPeer: Identifiable, Hashable {
    let id: String
    var deviceName: String
    var hostName: String?
    var ipAddress: String?
    var port: Int
    var nodeNumber: Int?
    var status: WallSyncPeerStatus
    var isController: Bool = false
    var tcpPort: UInt16 = 0
}
