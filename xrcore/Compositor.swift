import ARKit
import CoreVideo
import Metal
import MetalKit
import simd

// Swift-side uniform blocks — must mirror Shaders.metal exactly.
struct BackgroundUniforms {
    var uvScale = SIMD2<Float>()
    var uvOffset = SIMD2<Float>()
    var flipH: Float = 0
    var flipV: Float = 0
    var brightness: Float = 1
    var bgMode: Float = 0          // 0 camera, 1 dark, 2 home environment
}

struct ItemUniforms {
    var mvp = matrix_identity_float4x4
    var model = matrix_identity_float4x4
}

struct ItemFragUniforms {
    var color = SIMD4<Float>()
    var lightDir = SIMD4<Float>()
    var eyePos = SIMD4<Float>()
    var texTint = SIMD4<Float>()   // x = texture slot (0 untextured), y = hover glow
}

struct DistortionUniforms {
    var reproj0 = SIMD4<Float>()
    var reproj1 = SIMD4<Float>()
    var reproj2 = SIMD4<Float>()
    var tanHalf = SIMD2<Float>()
    var k1k2 = SIMD2<Float>()
    var grid = SIMD2<Float>()
    var timewarpOn: Float = 1
    var mono: Float = 0
}

// Compositor — three-pass stereo renderer:
//   1. background: passthrough / dark backdrop / home-environment gradient
//   2. scene:      client items (lit primitives + textured UI panels),
//                  premultiplied-alpha blending, shared per-eye depth
//   3. final:      lens distortion + rotational timewarp to the drawable
final class Compositor {

    let device: MTLDevice
    let queue: MTLCommandQueue
    private let library: MTLLibrary

    private var bgPipeline: MTLRenderPipelineState!
    private var scenePipeline: MTLRenderPipelineState!
    private var distortPipeline: MTLRenderPipelineState!
    private var depthStateWrite: MTLDepthStencilState!
    private var depthStateNoWrite: MTLDepthStencilState!

    private let meshes: [MeshKind: GPUMesh]

    private var cvCache: CVMetalTextureCache?
    private var frameCVTextures: [CVMetalTexture] = []   // keep wrappers alive per frame
    private var cvFlushCounter = 0
    private var dummyLuma: MTLTexture!
    private var dummyChroma: MTLTexture!

    private var sceneTexL: MTLTexture!
    private var sceneTexR: MTLTexture!
    private var depthTexL: MTLTexture!
    private var depthTexR: MTLTexture!
    private var rtSize = CGSize.zero
    private var rtMono = false
    private var rtScale: Float = 0

    private var jointsBuffer: MTLBuffer!

    private let gridCols = 32
    private let gridRows = 24
    private(set) var lastEyeAspect: Float = 0.9

    // Scene background mode requested by the shell (0 camera / 1 dark / 2 home).
    // The demo modes honor the passthrough setting; scan/home force sensible
    // values in VRHome.
    var sceneBackgroundMode: Int = 1

    // Texture registry for UI panels. IDs are stable handles handed to
    // xrc_scene_push_panel; textures re-bind each frame into slots 2..7.
    private let texLock = NSLock()
    private var panelTextures: [Int32: MTLTexture] = [:]
    private var nextTextureID: Int32 = 1

    init() {
        device = MTLCreateSystemDefaultDevice()!
        queue = device.makeCommandQueue()!
        library = device.makeDefaultLibrary()!
        meshes = MeshFactory.makeMeshes(device: device)

        buildPipelines()
        buildDepthStates()
        buildDummies()
        buildJointsBuffer()

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        cvCache = cache
    }

    private func buildPipelines() {
        // Background: attribute-free quad, everything in the fragment stage.
        let bg = MTLRenderPipelineDescriptor()
        bg.vertexFunction = library.makeFunction(name: "bgVertex")
        bg.fragmentFunction = library.makeFunction(name: "bgFragment")
        bg.colorAttachments[0].pixelFormat = .bgra8Unorm
        bgPipeline = try! device.makeRenderPipelineState(descriptor: bg)

        // Scene: position(0) + normal(1) + uv(2), 32-byte interleaved stride.
        let sc = MTLRenderPipelineDescriptor()
        sc.vertexFunction = library.makeFunction(name: "sceneVertex")
        sc.fragmentFunction = library.makeFunction(name: "sceneFragment")
        sc.colorAttachments[0].pixelFormat = .bgra8Unorm
        sc.colorAttachments[0].isBlendingEnabled = true
        sc.colorAttachments[0].sourceRGBBlendFactor = .one                 // premultiplied
        sc.colorAttachments[0].sourceAlphaBlendFactor = .one
        sc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        sc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        sc.depthAttachmentPixelFormat = .depth32Float
        let vdesc = MTLVertexDescriptor()
        vdesc.attributes[0].format = .float3
        vdesc.attributes[0].offset = 0
        vdesc.attributes[0].bufferIndex = 0
        vdesc.attributes[1].format = .float3
        vdesc.attributes[1].offset = 12
        vdesc.attributes[1].bufferIndex = 0
        vdesc.attributes[2].format = .float2
        vdesc.attributes[2].offset = 24
        vdesc.attributes[2].bufferIndex = 0
        vdesc.layouts[0].stride = 32
        vdesc.layouts[0].stepRate = 1
        vdesc.layouts[0].stepFunction = .perVertex
        sc.vertexDescriptor = vdesc
        scenePipeline = try! device.makeRenderPipelineState(descriptor: sc)

        // Final distortion pass.
        let di = MTLRenderPipelineDescriptor()
        di.vertexFunction = library.makeFunction(name: "distortVertex")
        di.fragmentFunction = library.makeFunction(name: "distortFragment")
        di.colorAttachments[0].pixelFormat = .bgra8Unorm
        distortPipeline = try! device.makeRenderPipelineState(descriptor: di)
    }

    private func buildDepthStates() {
        let w = MTLDepthStencilDescriptor()
        w.depthCompareFunction = .less
        w.isDepthWriteEnabled = true
        depthStateWrite = device.makeDepthStencilState(descriptor: w)

        // Translucent surfaces (planes, hover glows): read depth, don't write.
        let nw = MTLDepthStencilDescriptor()
        nw.depthCompareFunction = .less
        nw.isDepthWriteEnabled = false
        depthStateNoWrite = device.makeDepthStencilState(descriptor: nw)
    }

    private func buildDummies() {
        // CPU-filled textures need shared storage (replace() fails on .private).
        dummyLuma = makeTex(width: 1, height: 1, format: .r8Unorm, usage: .shaderRead, storage: .shared)
        var zero: UInt8 = 0
        dummyLuma.replace(region: MTLRegion(origin: MTLOrigin(), size: MTLSize(width: 1, height: 1, depth: 1)),
                          mipmapLevel: 0, withBytes: &zero, bytesPerRow: 1)
        dummyChroma = makeTex(width: 1, height: 1, format: .rg8Unorm, usage: .shaderRead, storage: .shared)
        var grey: [UInt8] = [128, 128]
        dummyChroma.replace(region: MTLRegion(origin: MTLOrigin(), size: MTLSize(width: 1, height: 1, depth: 1)),
                            mipmapLevel: 0, withBytes: &grey, bytesPerRow: 2)
    }

    private func buildJointsBuffer() {
        jointsBuffer = device.makeBuffer(length: 42 * MemoryLayout<SIMD2<Float>>.size, options: .storageModeShared)
    }

    private func makeTex(width: Int, height: Int, format: MTLPixelFormat, usage: MTLTextureUsage,
                         storage: MTLStorageMode = .private) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        d.usage = usage
        d.storageMode = storage
        return device.makeTexture(descriptor: d)!
    }

    // MARK: - panel texture registry

    func registerPanelTexture(_ tex: MTLTexture) -> Int32 {
        texLock.lock()
        defer { texLock.unlock() }
        let id = nextTextureID
        nextTextureID += 1
        panelTextures[id] = tex
        return id
    }

    // MARK: - view lifecycle

    func attach(view: MTKView) {
        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .invalid
        view.framebufferOnly = true
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 60
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        resize(to: view.drawableSize)
    }

    func resize(to size: CGSize) {
        let mono = settings.phoneMode
        let scale = min(max(Float(settings.renderScale), 0.5), 1.0)
        guard rtSize != size || rtMono != mono || rtScale != scale else { return }
        // renderScale launch option: per-eye resolution scale (renders at RT
        // resolution, distortion pass upscales to the drawable).
        let baseW = mono ? Int(size.width) : Int(size.width) / 2
        let w = max(Int(Float(baseW) * scale), 8)
        let h = max(Int(Float(size.height) * scale), 8)
        guard w > 8, h > 8 else { return }
        rtSize = size
        rtMono = mono
        rtScale = scale
        sceneTexL = makeTex(width: w, height: h, format: .bgra8Unorm, usage: [.renderTarget, .shaderRead])
        sceneTexR = makeTex(width: w, height: h, format: .bgra8Unorm, usage: [.renderTarget, .shaderRead])
        depthTexL = makeTex(width: w, height: h, format: .depth32Float, usage: .renderTarget)
        depthTexR = makeTex(width: w, height: h, format: .depth32Float, usage: .renderTarget)
        lastEyeAspect = Float(w) / Float(h)
    }

    // MARK: - projection (shared with the xrc API)

    func projection(eye: Int, nearZ: Float, farZ: Float) -> simd_float4x4 {
        XRCMath.perspectiveX(fovXDeg: Float(XRSettings.shared.fovDeg),
                             aspect: lastEyeAspect,
                             nearZ: nearZ, farZ: farZ)
    }

    // MARK: - frame

    func encodeFrame(view: MTKView,
                     arFrame: ARFrame,
                     predictedHead: simd_float4x4,
                     items: [XRCore.SceneItem],
                     joints: [SIMD2<Float>],
                     jointsActive: Bool) {
        guard let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer() else { return }

        let size = view.drawableSize
        let mono = settings.phoneMode
        let scale = min(max(Float(settings.renderScale), 0.5), 1.0)
        if rtSize != size || rtMono != mono || rtScale != scale { resize(to: size) }
        let eyeW = max(mono ? Int(size.width) : Int(size.width) / 2, 8)
        let eyeH = max(Int(size.height), 8)
        lastEyeAspect = Float(eyeW) / Float(eyeH)

        // --- camera passthrough textures ---
        frameCVTextures.removeAll(keepingCapacity: true)
        var lumaTex: MTLTexture?
        var chromaTex: MTLTexture?
        if sceneBackgroundMode == 0, settings.passthrough, CVPixelBufferGetPlaneCount(arFrame.capturedImage) == 2 {
            lumaTex = planeTexture(arFrame.capturedImage, plane: 0, format: .r8Unorm)
            chromaTex = planeTexture(arFrame.capturedImage, plane: 1, format: .rg8Unorm)
            // Unbounded cache growth = jetsam crash; flush stale entries every ~2 s.
            cvFlushCounter &+= 1
            if cvFlushCounter % 120 == 0, let cache = cvCache {
                CVMetalTextureCacheFlush(cache, 0)
            }
        }
        var mode = Float(sceneBackgroundMode)
        if sceneBackgroundMode == 0, lumaTex == nil || chromaTex == nil {
            mode = 1 // requested passthrough but no camera frame -> dark
        }
        let bindLuma = lumaTex ?? dummyLuma
        let bindChroma = chromaTex ?? dummyChroma

        // --- per-eye head poses (IPD offset along camera-right; none in mono) ---
        let head = arFrame.camera.transform
        let off = mono ? 0 : Float(settings.ipdMM) / 2000.0
        var poseL = head
        poseL.columns.3 = SIMD4<Float>(head.columns.3.xyz + head.columns.0.xyz * (-off), 1)
        var poseR = head
        poseR.columns.3 = SIMD4<Float>(head.columns.3.xyz + head.columns.0.xyz * off, 1)

        let proj = projection(eye: 0, nearZ: 0.05, farZ: 30)

        // --- background uniforms ---
        var bg = BackgroundUniforms()
        let fit = coverFit(eyeAspect: lastEyeAspect, zoom: Float(settings.ptZoom))
        bg.uvScale = fit.0
        bg.uvOffset = fit.1
        bg.flipH = settings.flipH ? 1 : 0
        bg.flipV = settings.flipV ? 1 : 0
        bg.brightness = Float(settings.ptBrightness)
        bg.bgMode = mode

        // --- joints debug buffer ---
        var jointCount = UInt32(0)
        if jointsActive && sceneBackgroundMode == 0 {
            let n = min(joints.count, 42)
            jointCount = UInt32(n)
            if n > 0 {
                let dst = jointsBuffer.contents().bindMemory(to: SIMD2<Float>.self, capacity: 42)
                for i in 0..<n { dst[i] = joints[i] }
            }
        }
        var ja: Float = jointCount > 0 ? 1 : 0

        // --- timewarp reproj (render -> predicted, rotation only) ---
        let qr = simd_quatf(head)
        let qp = simd_quatf(predictedHead)
        let m3 = simd_float3x3(qp.inverse * qr)
        var du = DistortionUniforms()
        du.reproj0 = SIMD4<Float>(m3.columns.0.x, m3.columns.0.y, m3.columns.0.z, 0)
        du.reproj1 = SIMD4<Float>(m3.columns.1.x, m3.columns.1.y, m3.columns.1.z, 0)
        du.reproj2 = SIMD4<Float>(m3.columns.2.x, m3.columns.2.y, m3.columns.2.z, 0)
        let fovX = Float(settings.fovDeg) * .pi / 180
        let tanX = tanf(fovX * 0.5)
        du.tanHalf = SIMD2<Float>(tanX, tanX / lastEyeAspect)
        du.k1k2 = SIMD2<Float>(Float(settings.lensK1), Float(settings.lensK2))
        du.grid = SIMD2<Float>(Float(gridCols), Float(gridRows))
        du.timewarpOn = settings.timewarp ? 1 : 0
        du.mono = mono ? 1 : 0

        let lightDir = SIMD4<Float>(normalize(SIMD3<Float>(0.3, 1.0, -0.4)), 0)

        // --- panel texture slot map: registry ids -> fragment slots 2..7 ---
        texLock.lock()
        let sortedIDs = panelTextures.keys.sorted()
        var slotOf: [Int32: Int] = [:]
        let boundTextures = sortedIDs.prefix(6).enumerated().map { (i, id) -> (Int32, MTLTexture) in
            slotOf[id] = i + 2
            return (id, panelTextures[id]!)
        }
        texLock.unlock()

        // --- pass 1 + 2 per eye (single pass in phone mode) ---
        let eyeTargets: [(Int, MTLTexture, MTLTexture)] = mono
            ? [(0, sceneTexL!, depthTexL!)]
            : [(0, sceneTexL!, depthTexL!), (1, sceneTexR!, depthTexR!)]
        for (eye, sceneTex, depthTex) in eyeTargets {
            let eyePose = eye == 0 ? poseL : poseR
            let viewM = eyePose.inverse

            // Background
            if let enc = cmd.makeRenderCommandEncoder(descriptor: passDesc(target: sceneTex, load: .clear)) {
                enc.setRenderPipelineState(bgPipeline)
                enc.setFragmentTexture(bindLuma, index: 0)
                enc.setFragmentTexture(bindChroma, index: 1)
                enc.setFragmentBytes(&bg, length: MemoryLayout<BackgroundUniforms>.size, index: 0)
                enc.setFragmentBuffer(jointsBuffer, offset: 0, index: 1)
                enc.setFragmentBytes(&jointCount, length: MemoryLayout<UInt32>.size, index: 2)
                enc.setFragmentBytes(&ja, length: MemoryLayout<Float>.size, index: 3)
                enc.drawPrimitives(type: MTLPrimitiveType.triangle, vertexStart: 0, vertexCount: 6)
                enc.endEncoding()
            }

            // Scene items
            if let enc = cmd.makeRenderCommandEncoder(descriptor: passDesc(target: sceneTex, load: .load, depth: depthTex)) {
                enc.setRenderPipelineState(scenePipeline)
                enc.setDepthStencilState(depthStateWrite)
                enc.setCullMode(MTLCullMode.back)
                enc.setFrontFacing(MTLWinding.counterClockwise)
                for (id, tex) in boundTextures {
                    enc.setFragmentTexture(tex, index: slotOf[id]!)
                }
                for item in items {
                    var vu = ItemUniforms(mvp: proj * viewM * item.model, model: item.model)
                    // Shader indexes fragment texture slots; registry id -> slot.
                    let texSlot = slotOf[item.texIndex] ?? 0
                    var fu = ItemFragUniforms(color: item.color, lightDir: lightDir,
                                              eyePos: SIMD4<Float>(eyePose.columns.3.xyz, 1),
                                              texTint: SIMD4<Float>(Float(texSlot), item.glow, 0, 0))
                    let mesh = meshes[item.kind] ?? meshes[.box]!
                    enc.setVertexBuffer(mesh.vertexBuffer, offset: 0, index: 0)
                    enc.setVertexBytes(&vu, length: MemoryLayout<ItemUniforms>.size, index: 1)
                    enc.setFragmentBytes(&fu, length: MemoryLayout<ItemFragUniforms>.size, index: 0)
                    if item.color.w < 0.99 { enc.setDepthStencilState(depthStateNoWrite) }
                    enc.drawPrimitives(type: MTLPrimitiveType.triangle, vertexStart: 0, vertexCount: mesh.vertexCount)
                    if item.color.w < 0.99 { enc.setDepthStencilState(depthStateWrite) }
                }
                enc.endEncoding()
            }
        }

        // --- pass 3: distortion + timewarp to drawable ---
        if let enc = cmd.makeRenderCommandEncoder(descriptor: passDesc(target: drawable.texture, load: .clear)) {
            enc.setRenderPipelineState(distortPipeline)
            enc.setVertexBytes(&du, length: MemoryLayout<DistortionUniforms>.size, index: 0)
            enc.setFragmentTexture(sceneTexL!, index: 0)
            enc.setFragmentTexture(sceneTexR!, index: 1)
            enc.drawPrimitives(type: MTLPrimitiveType.triangle, vertexStart: 0, vertexCount: gridCols * gridRows * 6 * 2)
            enc.endEncoding()
        }

        cmd.present(drawable)
        cmd.addCompletedHandler { [weak self] _ in
            self?.frameCVTextures.removeAll()
        }
        cmd.commit()
    }

    // MARK: - helpers

    private func passDesc(target: MTLTexture, load: MTLLoadAction, depth: MTLTexture? = nil) -> MTLRenderPassDescriptor {
        let d = MTLRenderPassDescriptor()
        d.colorAttachments[0].texture = target
        d.colorAttachments[0].loadAction = load
        d.colorAttachments[0].storeAction = .store
        d.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        if let depth = depth {
            d.depthAttachment.texture = depth
            d.depthAttachment.loadAction = .clear
            d.depthAttachment.storeAction = .dontCare
            d.depthAttachment.clearDepth = 1.0
        }
        return d
    }

    private func planeTexture(_ pb: CVPixelBuffer, plane: Int, format: MTLPixelFormat) -> MTLTexture? {
        guard let cache = cvCache else { return nil }
        var cvtex: CVMetalTexture?
        let w = CVPixelBufferGetWidthOfPlane(pb, plane)
        let h = CVPixelBufferGetHeightOfPlane(pb, plane)
        let status = CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, format, w, h, plane, &cvtex)
        guard status == kCVReturnSuccess, let wrapper = cvtex, let tex = CVMetalTextureGetTexture(wrapper) else { return nil }
        frameCVTextures.append(wrapper) // keep alive until the command buffer completes
        return tex
    }

    private func coverFit(eyeAspect: Float, zoom: Float) -> (SIMD2<Float>, SIMD2<Float>) {
        let bufAspect: Float = 4.0 / 3.0
        var sx: Float
        var sy: Float
        if bufAspect > eyeAspect {
            sy = 1
            sx = eyeAspect / bufAspect
        } else {
            sx = 1
            sy = bufAspect / eyeAspect
        }
        let z = max(zoom, 0.5)
        sx /= z
        sy /= z
        return (SIMD2<Float>(sx, sy), SIMD2<Float>((1 - sx) * 0.5, (1 - sy) * 0.5))
    }

    private var settings: XRSettings { XRSettings.shared }
}
