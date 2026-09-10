import Metal

public enum CineRendererError: Error, CustomStringConvertible {
    case commandQueueCreationFailed
    case shaderLibraryNotFound
    case functionNotFound(String)
    case pipelineCreationFailed(String)

    public var description: String {
        switch self {
        case .commandQueueCreationFailed:
            return "Failed to create a Metal command queue."
        case .shaderLibraryNotFound:
            return "Could not locate default.metallib in the resource bundle."
        case .functionNotFound(let name):
            return "Metal function '\(name)' not found in the shader library."
        case .pipelineCreationFailed(let reason):
            return "Failed to create the tonemap render pipeline state: \(reason)"
        }
    }
}

/// Renders a raw `.r16Uint` sensor texture into an arbitrary color render
/// target, applying the linear black/white tone-mapping fragment shader.
/// Supports two render-target formats, each with its own
/// `MTLRenderPipelineState` built at `init` time since a pipeline's declared
/// `colorAttachments[0].pixelFormat` must match its render target:
/// `.bgra8Unorm` (live view, `FrameExporter`, `cine-diagnostic`) and
/// `.rgba16Unorm` (16-bit TIFF range export, see `RangeExporter`). Both share
/// the same `tonemapVertex`/`tonemapFragment` functions — the fragment
/// shader's linear `float4` output is quantized by the GPU to whichever bit
/// depth the bound target declares, so no shader changes were needed.
///
/// This is the single code path for the tone-mapping render pass — the live
/// `MTKView` delegate, the offscreen `cine-diagnostic` CLI, and the app's
/// frame exporters all call through `render(rawTexture:uniforms:into:colorAttachment:)`.
public final class CineRenderer {
    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue

    private let pipelineState: MTLRenderPipelineState
    private let pipelineState16Bit: MTLRenderPipelineState
    /// Bound at the fragment shader's LUT texture slot (index 1) whenever
    /// `render(...)` isn't given a real `lutTexture` — Metal requires
    /// *something* valid bound to any texture argument a fragment function
    /// declares, even when `uniforms.lutEnabled == 0` skips sampling it.
    private let dummyLUTTexture: MTLTexture
    /// Bound at the four tone-curve texture slots (indices 2-5) when not
    /// otherwise given — always sampled (no enable flag), so it must be a
    /// genuine identity ramp.
    private let dummyToneCurveTexture: MTLTexture

    /// - Parameter bundle: Resource bundle to load `CinePlayerShaders.metallib`
    ///   from (not "default.metallib" — see `Plugins/MetalShaderPlugin/plugin.swift`).
    ///   `nil` (the default) uses `Bundle.module`; resolved inside the
    ///   initializer since `Bundle.module` is internal and can't appear in a
    ///   public default parameter value.
    public init(device: MTLDevice, bundle: Bundle? = nil) throws {
        self.device = device

        guard let queue = device.makeCommandQueue() else {
            throw CineRendererError.commandQueueCreationFailed
        }
        self.commandQueue = queue

        let resourceBundle = bundle ?? Bundle.module
        guard let metallibURL = resourceBundle.url(forResource: "CinePlayerShaders", withExtension: "metallib") else {
            throw CineRendererError.shaderLibraryNotFound
        }
        let library = try device.makeLibrary(URL: metallibURL)

        guard let vertexFunction = library.makeFunction(name: "tonemapVertex") else {
            throw CineRendererError.functionNotFound("tonemapVertex")
        }
        guard let fragmentFunction = library.makeFunction(name: "tonemapFragment") else {
            throw CineRendererError.functionNotFound("tonemapFragment")
        }

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        do {
            self.pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            throw CineRendererError.pipelineCreationFailed(String(describing: error))
        }

        // Same vertex/fragment functions, only the target pixel format
        // differs. Used only by 16-bit TIFF range export today.
        let pipelineDescriptor16Bit = MTLRenderPipelineDescriptor()
        pipelineDescriptor16Bit.vertexFunction = vertexFunction
        pipelineDescriptor16Bit.fragmentFunction = fragmentFunction
        pipelineDescriptor16Bit.colorAttachments[0].pixelFormat = .rgba16Unorm

        do {
            self.pipelineState16Bit = try device.makeRenderPipelineState(descriptor: pipelineDescriptor16Bit)
        } catch {
            throw CineRendererError.pipelineCreationFailed(String(describing: error))
        }

        self.dummyLUTTexture = try LUTTexture.makeIdentityDummy(device: device)
        self.dummyToneCurveTexture = try ToneCurveTexture.makeIdentityDummy(device: device)
    }

    /// Encodes the full-screen tone-mapping render pass into `commandBuffer`,
    /// reading `rawTexture` and writing into `colorAttachment`.
    ///
    /// `colorAttachment.pixelFormat` must be `.bgra8Unorm` or `.rgba16Unorm`,
    /// selecting the matching pipeline built at `init` time. Any other
    /// format is a programmer error, not a runtime condition to recover
    /// from, so it traps via `preconditionFailure` (unlike `assert`, this
    /// still traps in Release builds).
    ///
    /// The caller owns the command buffer's lifecycle: for a live view,
    /// commit (and present the drawable) afterwards; for an offscreen
    /// render, commit and wait for completion before reading pixels back.
    ///
    /// - Parameter lutTexture: optional 3D color-grading LUT texture (see
    ///   `LUTTexture.make(from:device:)`). `nil` (default) binds this
    ///   renderer's dummy identity texture instead; `uniforms.lutEnabled`
    ///   decides whether it's actually sampled, so existing call sites keep
    ///   rendering unchanged.
    /// - Parameter toneCurveTextures: the four tone-curve textures (primary +
    ///   R/G/B). `nil` (or any missing channel) falls back to the dummy
    ///   identity ramp.
    /// - Parameter grading: "Cine Colour" grading uniforms (see
    ///   `GradingUniforms`), bound to both stages at buffer index 1.
    ///   `.identity` (default) is a true no-op, so existing call sites keep
    ///   rendering unchanged.
    /// - Parameter viewport: on-screen zoom/pan transform (see
    ///   `ViewportUniforms`), bound only to the vertex stage at buffer index
    ///   2. `.identity` (default) is a true no-op through `tonemapVertex`'s
    ///   UV remap, so existing call sites keep rendering unchanged.
    public func render(
        rawTexture: MTLTexture,
        uniforms: ExposureUniforms,
        into commandBuffer: MTLCommandBuffer,
        colorAttachment: MTLTexture,
        lutTexture: MTLTexture? = nil,
        grading: GradingUniforms = .identity,
        viewport: ViewportUniforms = .identity,
        toneCurveTextures: ToneCurveTextureSet? = nil
    ) {
        let selectedPipeline: MTLRenderPipelineState
        switch colorAttachment.pixelFormat {
        case .bgra8Unorm:
            selectedPipeline = pipelineState
        case .rgba16Unorm:
            selectedPipeline = pipelineState16Bit
        default:
            preconditionFailure(
                "CineRenderer.render: colorAttachment.pixelFormat (\(colorAttachment.pixelFormat)) "
                    + "matches neither pipeline state this renderer was built with (.bgra8Unorm or "
                    + ".rgba16Unorm) — this is a programmer error, not a runtime condition to recover from."
            )
        }

        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = colorAttachment
        passDescriptor.colorAttachments[0].loadAction = .clear
        passDescriptor.colorAttachments[0].storeAction = .store
        passDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            return
        }
        encoder.setRenderPipelineState(selectedPipeline)
        encoder.setFragmentTexture(rawTexture, index: 0)
        encoder.setFragmentTexture(lutTexture ?? dummyLUTTexture, index: 1)
        encoder.setFragmentTexture(toneCurveTextures?.primary ?? dummyToneCurveTexture, index: 2)
        encoder.setFragmentTexture(toneCurveTextures?.red ?? dummyToneCurveTexture, index: 3)
        encoder.setFragmentTexture(toneCurveTextures?.green ?? dummyToneCurveTexture, index: 4)
        encoder.setFragmentTexture(toneCurveTextures?.blue ?? dummyToneCurveTexture, index: 5)

        var mutableUniforms = uniforms
        withUnsafeBytes(of: &mutableUniforms) { raw in
            encoder.setVertexBytes(raw.baseAddress!, length: raw.count, index: 0)
            encoder.setFragmentBytes(raw.baseAddress!, length: raw.count, index: 0)
        }

        var mutableGrading = grading
        withUnsafeBytes(of: &mutableGrading) { raw in
            encoder.setVertexBytes(raw.baseAddress!, length: raw.count, index: 1)
            encoder.setFragmentBytes(raw.baseAddress!, length: raw.count, index: 1)
        }

        var mutableViewport = viewport
        withUnsafeBytes(of: &mutableViewport) { raw in
            encoder.setVertexBytes(raw.baseAddress!, length: raw.count, index: 2)
        }

        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }
}
