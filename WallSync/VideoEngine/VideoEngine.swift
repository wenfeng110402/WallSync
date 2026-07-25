import Foundation
import Combine
import AVFoundation
import CoreMedia
import CoreVideo

/// 视频引擎状态
enum VideoEngineState: Equatable {
    case idle
    case loading
    case ready
    case playing
    case paused
    case stopped
    case failed(Error)

    static func == (lhs: VideoEngineState, rhs: VideoEngineState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.loading, .loading), (.ready, .ready),
             (.playing, .playing), (.paused, .paused), (.stopped, .stopped):
            return true
        case (.failed(let lhsError), .failed(let rhsError)):
            return lhsError.localizedDescription == rhsError.localizedDescription
        default:
            return false
        }
    }
}

/// 视频引擎 — 使用 AVAssetReader 读取视频帧输出 CVPixelBuffer
/// 不使用 AVPlayer，实现低层级 GPU 帧访问
final class VideoEngine: ObservableObject {
    @Published private(set) var state: VideoEngineState = .idle
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var naturalSize: CGSize = .zero
    @Published private(set) var frameRate: Float = 0

    private var asset: AVAsset?
    private var assetReader: AVAssetReader?
    private var trackOutput: AVAssetReaderTrackOutput?
    private var displayLink: CVDisplayLink?

    // 解码队列
    private let decodeQueue = DispatchQueue(label: "com.wallsync.video.decode", qos: .userInteractive)
    // 帧回调
    var onFrameDecoded: ((CVPixelBuffer, CMTime) -> Void)?

    private var isReading = false
    private var startTime: CMTime = .zero
    private var rate: Float = 1.0
    private var lastPausedTime: CMTime = .zero
    private var videoTrack: AVAssetTrack?

    /// 加载视频文件
    func load(url: URL) async throws {
        await MainActor.run { state = .loading }

        let asset = AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true
        ])

        try await asset.load(.tracks, .duration, .preferredRate, .preferredTransform)

        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoEngineError.noVideoTrack
        }

        let duration = try await asset.load(.duration).seconds
        let naturalSize = try await track.load(.naturalSize)
        let frameRate = try await track.load(.nominalFrameRate)

        await MainActor.run {
            self.asset = asset
            self.videoTrack = track
            self.duration = duration
            self.naturalSize = naturalSize
            self.frameRate = frameRate
            self.state = .ready
        }
    }

    /// 开始播放
    func play() {
        guard state == .ready || state == .paused else { return }

        if state == .ready {
            startReading(from: .zero)
        } else if state == .paused {
            startReading(from: lastPausedTime)
        }
    }

    /// 暂停
    func pause() {
        guard state == .playing else { return }
        isReading = false
        lastPausedTime = CMTime(seconds: currentTime, preferredTimescale: 600)
        cancelReading()
        DispatchQueue.main.async {
            self.state = .paused
        }
    }

    /// 停止
    func stop() {
        isReading = false
        cancelReading()
        DispatchQueue.main.async {
            self.state = .stopped
            self.currentTime = 0
        }
    }

    /// 跳转到指定时间
    func seek(to time: TimeInterval) {
        isReading = false
        cancelReading()
        let targetTime = CMTime(seconds: time, preferredTimescale: 600)
        lastPausedTime = targetTime

        if state == .playing {
            startReading(from: targetTime)
        } else {
            DispatchQueue.main.async {
                self.currentTime = time
            }
        }
    }

    /// 清理资源
    func clear() {
        isReading = false
        cancelReading()
        asset = nil
        videoTrack = nil
        DispatchQueue.main.async {
            self.state = .idle
            self.currentTime = 0
            self.duration = 0
            self.naturalSize = .zero
            self.frameRate = 0
        }
    }

    // MARK: - 内部读取逻辑

    private func startReading(from time: CMTime) {
        guard let asset = asset, let track = videoTrack else { return }

        cancelReading()

        do {
            let reader = try AVAssetReader(asset: asset)
            reader.timeRange = CMTimeRange(
                start: time,
                duration: CMTime(seconds: .greatestFiniteMagnitude, preferredTimescale: 600)
            )

            let output = AVAssetReaderTrackOutput(
                track: track,
                outputSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferMetalCompatibilityKey as String: true,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:]
                ]
            )
            output.alwaysCopiesSampleData = false

            guard reader.canAdd(output) else {
                throw VideoEngineError.cannotAddOutput
            }
            reader.add(output)

            guard reader.startReading() else {
                throw VideoEngineError.readerFailed(reader.error)
            }

            assetReader = reader
            trackOutput = output
            isReading = true
            startTime = time

            DispatchQueue.main.async {
                self.state = .playing
                self.currentTime = time.seconds
            }

            // 开始异步解码
            decodeQueue.async { [weak self] in
                self?.readLoop()
            }

        } catch {
            DispatchQueue.main.async {
                self.state = .failed(error)
            }
        }
    }

    private func readLoop() {
        guard let output = trackOutput else { return }

        while isReading {
            guard let sampleBuffer = output.copyNextSampleBuffer() else {
                // 视频读取完毕
                if isReading {
                    DispatchQueue.main.async {
                        self.state = .stopped
                    }
                }
                break
            }

            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                continue
            }

            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

            DispatchQueue.main.async {
                self.currentTime = timestamp.seconds
            }

            onFrameDecoded?(pixelBuffer, timestamp)
        }
    }

    private func cancelReading() {
        trackOutput = nil
        assetReader?.cancelReading()
        assetReader = nil
    }

    deinit {
        isReading = false
        cancelReading()
    }
}

// MARK: - 错误类型
enum VideoEngineError: LocalizedError {
    case noVideoTrack
    case cannotAddOutput
    case readerFailed(Error?)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            return "文件中没有视频轨道"
        case .cannotAddOutput:
            return "无法添加读取输出"
        case .readerFailed(let error):
            return "读取器失败: \(error?.localizedDescription ?? "未知错误")"
        }
    }
}
