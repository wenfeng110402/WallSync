import Foundation
import CoreGraphics

/// 视频墙布局配置
struct WallLayoutConfig: Codable, Identifiable, Equatable, Hashable {
    var id: String { "\(columns)x\(rows)" }

    let columns: Int
    let rows: Int

    var totalNodes: Int { columns * rows }

    static let preset5x2 = WallLayoutConfig(columns: 5, rows: 2)
    static let preset3x3 = WallLayoutConfig(columns: 3, rows: 3)
    static let preset4x2 = WallLayoutConfig(columns: 4, rows: 2)
    static let preset2x2 = WallLayoutConfig(columns: 2, rows: 2)
    static let preset6x2 = WallLayoutConfig(columns: 6, rows: 2)

    static var allPresets: [WallLayoutConfig] {
        [.preset2x2, .preset3x3, .preset4x2, .preset5x2, .preset6x2]
    }
}

/// 节点显示区域分配
struct RegionAssignment: Codable, Identifiable {
    let nodeID: String
    let nodeIndex: Int
    let originX: Int
    let originY: Int
    let width: Int
    let height: Int

    var id: String { nodeID }

    /// 归一化的 UV 坐标 (0~1)
    var uvRect: CGRect {
        CGRect(
            x: CGFloat(originX),
            y: CGFloat(originY),
            width: CGFloat(width),
            height: CGFloat(height)
        )
    }
}

/// 节点网络信息
struct NodeConnectionInfo: Codable, Identifiable {
    let nodeID: String
    let deviceName: String
    let ipAddress: String
    let port: UInt16
    var nodeIndex: Int
    var isConnected: Bool
    var latencyMs: Double

    var id: String { nodeID }
}
