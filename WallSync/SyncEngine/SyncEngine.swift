import Foundation
import Combine
import CoreMedia
import QuartzCore

/// 同步引擎
/// 基于 CoreMedia 时钟和 mach_absolute_time 实现多机时间同步
///
/// 核心算法：
/// 1. 主控发送 SyncSignal，包含 controllerMachTime 和 presentationTime
/// 2. 节点收到后记录本地 mach_absolute_time
/// 3. 计算时间偏移: offset = controllerMachTime - localMachTime
/// 4. 多个样本滑动平均，过滤异常值
/// 5. 目标：10 台 Mac 同步误差 < 10ms
final class SyncEngine: ObservableObject {
    @Published private(set) var timeOffset: Double = 0
    @Published private(set) var estimatedLatency: Double = 0
    @Published private(set) var syncQuality: SyncQuality = .unknown
    @Published private(set) var samplesCollected: Int = 0
    @Published private(set) var lastSyncTime: TimeInterval = 0

    enum SyncQuality: String {
        case unknown = "未同步"
        case poor = "差"
        case fair = "一般"
        case good = "良好"
        case excellent = "优秀"
    }

    /// 时间偏移历史样本
    private var offsetSamples: [(offset: Double, latency: Double)] = []
    private let maxSamples = 100
    private let minSamplesForSync = 10

    /// mach_time 转换因子
    private let machTimeInfo: mach_timebase_info = {
        var info = mach_timebase_info()
        mach_timebase_info(&info)
        return info
    }()

    /// 将 mach_absolute_time 转换为秒
    private func machTimeToSeconds(_ time: UInt64) -> Double {
        let nanos = time * UInt64(machTimeInfo.numer) / UInt64(machTimeInfo.denom)
        return Double(nanos) / 1_000_000_000
    }

    /// 获取当前时间（秒）
    var currentTimeSeconds: Double {
        machTimeToSeconds(mach_absolute_time())
    }

    /// 节点端：处理接收到的同步信号
    /// - Returns: 经校准后的本地呈现时间
    func processSyncSignal(_ signal: SyncSignal) -> TimeInterval {
        let localMach = mach_absolute_time()
        let localTime = machTimeToSeconds(localMach)
        let controllerTime = machTimeToSeconds(signal.controllerMachTime)

        // 估算单程延迟
        let latency = abs(localTime - controllerTime) / 2.0
        // 时间偏移
        let offset = controllerTime - localTime

        // 添加到样本
        offsetSamples.append((offset, latency))
        if offsetSamples.count > maxSamples {
            offsetSamples.removeFirst()
        }

        samplesCollected = offsetSamples.count

        // 过滤异常值（超出 3 倍标准差）
        let filtered = filterOutliers(offsetSamples.map(\.offset))

        // 计算滑动平均
        if !filtered.isEmpty {
            timeOffset = filtered.reduce(0, +) / Double(filtered.count)
        }

        // 估算延迟中位数
        let latencies = offsetSamples.map(\.latency).sorted()
        if latencies.count > 0 {
            estimatedLatency = latencies[latencies.count / 2]
        }

        // 评估同步质量
        updateSyncQuality()

        lastSyncTime = CACurrentMediaTime()

        // 计算校准后的呈现时间
        let calibratedTime = signal.presentationTime + timeOffset

        return calibratedTime
    }

    /// 主控端：生成带时间戳的呈现时间
    func generatePresentationTime(baseTime: TimeInterval, playbackRate: Float) -> TimeInterval {
        // 基于主控本地时钟的呈现时间
        baseTime
    }

    /// 将主控的呈现时间转换为本地校准时间
    func calibratePresentationTime(_ controllerTime: TimeInterval) -> TimeInterval {
        controllerTime + timeOffset
    }

    /// 重置同步状态
    func reset() {
        offsetSamples.removeAll()
        timeOffset = 0
        estimatedLatency = 0
        syncQuality = .unknown
        samplesCollected = 0
        lastSyncTime = 0
    }

    // MARK: - 辅助方法

    private func filterOutliers(_ samples: [Double]) -> [Double] {
        guard samples.count >= 4 else { return samples }

        let mean = samples.reduce(0, +) / Double(samples.count)
        let variance = samples.map { pow($0 - mean, 2) }.reduce(0, +) / Double(samples.count)
        let stdDev = sqrt(variance)
        let threshold = 3.0 * stdDev

        return samples.filter { abs($0 - mean) <= threshold }
    }

    private func updateSyncQuality() {
        let latencyMs = estimatedLatency * 1000

        switch latencyMs {
        case ..<0.5:
            syncQuality = samplesCollected >= minSamplesForSync ? .excellent : .unknown
        case ..<1.0:
            syncQuality = samplesCollected >= minSamplesForSync ? .good : .unknown
        case ..<2.0:
            syncQuality = samplesCollected >= minSamplesForSync ? .fair : .unknown
        case ..<5.0:
            syncQuality = samplesCollected >= minSamplesForSync ? .poor : .unknown
        default:
            syncQuality = .poor
        }
    }

    /// 主控端：获取当前精确时间（用于对比）
    static var currentMachTime: UInt64 {
        mach_absolute_time()
    }
}
