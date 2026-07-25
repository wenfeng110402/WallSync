import Foundation
import CoreMedia
import QuartzCore

// MARK: - TCP 控制消息类型
enum ControlMessageType: String, Codable {
    // 节点注册
    case registerNode
    case nodeRegistered
    case nodeDisconnected

    // 播放控制
    case startPlayback
    case pausePlayback
    case stopPlayback
    case seekTo

    // 布局与区域
    case layoutUpdate
    case regionAssignment

    // 视频信息
    case videoInfo
    case videoFileReady

    // 连接保活
    case heartbeat
    case heartbeatAck

    // 延迟测量
    case latencyPing
    case latencyPong
}

/// TCP 控制消息（JSON 编码）
struct ControlMessage: Codable {
    let type: ControlMessageType
    let payload: Data?
    let sequenceNumber: UInt64
    let timestamp: TimeInterval

    init(type: ControlMessageType, payload: Data? = nil, sequenceNumber: UInt64 = 0) {
        self.type = type
        self.payload = payload
        self.sequenceNumber = sequenceNumber
        self.timestamp = CACurrentMediaTime()
    }

    func encoded() -> Data? {
        var data = try? JSONEncoder().encode(self)
        // 添加长度前缀以便在 TCP 流中分割
        guard let body = data else { return nil }
        var length = UInt32(body.count).bigEndian
        var packet = Data(bytes: &length, count: 4)
        packet.append(body)
        return packet
    }

    static func decode(from data: Data) -> (message: ControlMessage, consumed: Int)? {
        // 需要至少 4 字节的长度前缀
        guard data.count >= 4 else { return nil }

        // 从字节安全地读取 big-endian 的 UInt32，避免未对齐的 load()
        let length: UInt32 = data.prefix(4).reduce(0) { partial, byte in
            return (partial << 8) | UInt32(byte)
        }

        let totalSize = Int(length) + 4
        guard data.count >= totalSize else { return nil }

        let body = data[4..<totalSize]
        guard let message = try? JSONDecoder().decode(ControlMessage.self, from: body) else { return nil }
        return (message, totalSize)
    }
}

// MARK: - UDP 同步信号

/// UDP 同步信号（低延迟）
struct SyncSignal: Codable {
    /// 主控发起的全局呈现时间戳（秒）
    let presentationTime: TimeInterval
    /// 序列号，用于检测丢包
    let sequenceNumber: UInt64
    /// 主控发送时的 mach_absolute_time
    let controllerMachTime: UInt64
    /// 当前播放速率 (1.0 = 正常)
    let rate: Float
    /// 当前播放状态
    let state: PlaybackState

    enum PlaybackState: String, Codable {
        case playing
        case paused
        case stopped
    }

    init(presentationTime: TimeInterval, sequenceNumber: UInt64, rate: Float, state: PlaybackState) {
        self.presentationTime = presentationTime
        self.sequenceNumber = sequenceNumber
        self.controllerMachTime = mach_absolute_time()
        self.rate = rate
        self.state = state
    }

    func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    static func decode(from data: Data) -> SyncSignal? {
        try? JSONDecoder().decode(SyncSignal.self, from: data)
    }
}

// MARK: - 视频信息

struct VideoInfoPayload: Codable {
    let filePath: String
    let duration: TimeInterval
    let naturalWidth: Int
    let naturalHeight: Int
    let videoID: String
}

// MARK: - 布局更新

struct LayoutUpdatePayload: Codable {
    let layout: WallLayoutConfig
    let assignments: [RegionAssignment]
    let videoNaturalSize: CGSize
}
