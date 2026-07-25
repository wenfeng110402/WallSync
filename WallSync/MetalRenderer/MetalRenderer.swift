import Foundation
import Combine
import Metal
import MetalKit
import CoreVideo
import SwiftUI

/// Metal 视频渲染器
/// 使用 GPU 渲染 CVPixelBuffer，支持区域裁剪
final class MetalRenderer: NSObject, ObservableObject {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let metalView: MTKView

    private var pipelineState: MTLRenderPipelineState?
    private var textureCache: CVMetalTextureCache?
    private var currentTexture: MTLTexture?

    // 区域裁剪参数
    @Published var regionOffsetX: Float = 0
    @Published var regionOffsetY: Float = 0
    @Published var regionScaleX: Float = 1
    @Published var regionScaleY: Float = 1

    private var regionUniforms = RegionUniforms(offsetX: 0, offsetY: 0, scaleX: 1, scaleY: 1)
    private var uniformBuffer: MTLBuffer?

    // 性能统计
    @Published private(set) var frameRate: Double = 0
    private var frameCount: UInt64 = 0
    private var lastFrameTime = mach_absolute_time()

    struct RegionUniforms {
        let offsetX: Float
        let offsetY: Float
        let scaleX: Float
        let scaleY: Float
    }

    override init() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal 不可用")
        }
        self.device = device
        self.commandQueue = device.makeCommandQueue()!
        self.metalView = MTKView(frame: .zero, device: device)

        super.init()

        metalView.device = device
        metalView.delegate = self
        metalView.framebufferOnly = true
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.enableSetNeedsDisplay = false
        metalView.isPaused = false
        metalView.preferredFramesPerSecond = 60

        setupPipeline()
        setupTextureCache()
        setupUniformBuffer()
    }

    private func setupPipeline() {
        guard let library = device.makeDefaultLibrary() else {
            // 如果没有 .metal 文件，使用内置着色器
            return
        }

        let vertexFunc = library.makeFunction(name: "vertex_cropped")
        let fragmentFunc = library.makeFunction(name: "fragment_main")

        guard let vertexFunc = vertexFunc, let fragmentFunc = fragmentFunc else {
            print("[Metal] 着色器加载失败，使用基本管线")
            createSimplePipeline()
            return
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunc
        descriptor.fragmentFunction = fragmentFunc
        descriptor.colorAttachments[0].pixelFormat = metalView.colorPixelFormat

        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            print("[Metal] 渲染管线创建失败: \(error)")
        }
    }

    private func createSimplePipeline() {
        // 使用内置的 Metal 着色器（无裁剪）作为后备
        guard let library = device.makeDefaultLibrary() else {
            print("[Metal] 无法创建默认库")
            return
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "vertex_main")
        descriptor.fragmentFunction = library.makeFunction(name: "fragment_main")
        descriptor.colorAttachments[0].pixelFormat = metalView.colorPixelFormat

        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            print("[Metal] 回退管线创建失败: \(error)")
        }
    }

    private func setupTextureCache() {
        var cache: CVMetalTextureCache?
        let result = CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            device,
            nil,
            &cache
        )
        if result == kCVReturnSuccess {
            textureCache = cache
        } else {
            print("[Metal] CVMetalTextureCache 创建失败: \(result)")
        }
    }

    private func setupUniformBuffer() {
        uniformBuffer = device.makeBuffer(
            length: MemoryLayout<RegionUniforms>.stride,
            options: .storageModeShared
        )
    }

    /// 更新区域裁剪参数
    func updateRegion(offsetX: Float, offsetY: Float, scaleX: Float, scaleY: Float) {
        regionOffsetX = offsetX
        regionOffsetY = offsetY
        regionScaleX = scaleX
        regionScaleY = scaleY
    }

    /// 传入新的 CVPixelBuffer 进行渲染
    func enqueuePixelBuffer(_ pixelBuffer: CVPixelBuffer) {
        guard let textureCache = textureCache else { return }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var texture: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &texture
        )

        if result == kCVReturnSuccess, let cvTexture = texture, let metalTexture = CVMetalTextureGetTexture(cvTexture) {
            currentTexture = metalTexture
        }

        // 帧率统计
        frameCount += 1
        let now = mach_absolute_time()
        let elapsed = Double(now - lastFrameTime) / 1_000_000_000
        if elapsed >= 1.0 {
            frameRate = Double(frameCount) / elapsed
            frameCount = 0
            lastFrameTime = now
        }
    }

    /// 清空当前纹理
    func clearTexture() {
        currentTexture = nil
    }

    /// 获取 SwiftUI 包装视图
    var swiftUIView: MetalRendererContainer {
        MetalRendererContainer(renderer: self)
    }
}

// MARK: - MTKView Delegate
extension MetalRenderer: MTKViewDelegate {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // 处理尺寸变化
    }

    func draw(in view: MTKView) {
        guard let pipelineState = pipelineState,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable else {
            return
        }

        // 更新裁剪参数 Uniform
        if let uniformBuffer = uniformBuffer {
            let ptr = uniformBuffer.contents()
            let uniforms = RegionUniforms(
                offsetX: regionOffsetX,
                offsetY: regionOffsetY,
                scaleX: regionScaleX,
                scaleY: regionScaleY
            )
            ptr.copyMemory(from: [uniforms], byteCount: MemoryLayout<RegionUniforms>.stride)
        }

        descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }

        encoder.setRenderPipelineState(pipelineState)

        if let uniformBuffer = uniformBuffer {
            encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 0)
        }

        if let texture = currentTexture {
            encoder.setFragmentTexture(texture, index: 0)
        }

        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

// MARK: - SwiftUI 包装
struct MetalRendererContainer: NSViewRepresentable {
    let renderer: MetalRenderer

    func makeNSView(context: Context) -> MTKView {
        renderer.metalView
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        // 不需要更新
    }
}
