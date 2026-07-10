import Foundation
import Metal
import MetalKit
import simd

// Must match `struct Params` in Shaders.swift exactly (field order + alignment).
struct Params {
    var count: UInt32 = 0
    var dt: Float = 0
    var speed: Float = 0
    var frame: UInt32 = 0
    var aspect: SIMD2<Float> = .init(1, 1)
    var pointSize: Float = 0
    var lifeMin: Float = 0
    var lifeMax: Float = 0
    var fade: Float = 0
    var alpha: Float = 1
}

final class Renderer: NSObject, MTKViewDelegate {

    // ---- live tunables (adjusted at runtime via the panel / keyboard) ------
    private var particleCount = 500_000
    private var speed: Float = 0.45
    private var pointSize: Float = 1.1
    private var fade: Float = 0.09
    private var lifeMin: Float = 2.0
    private var lifeMax: Float = 9.0
    private var showVortices = true
    private let gridFallback = 64
    private let maxVortices = 200

    var onStatus: ((String) -> Void)?

    // ---- Metal objects -----------------------------------------------------
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let colorPixelFormat: MTLPixelFormat

    private var advectPSO: MTLComputePipelineState!
    private var pointPSO: MTLRenderPipelineState!
    private var fadePSO: MTLRenderPipelineState!
    private var presentPSO: MTLRenderPipelineState!
    private var markerPSO: MTLRenderPipelineState!

    private var posBuf: MTLBuffer!
    private var lifeBuf: MTLBuffer!
    private var spdBuf: MTLBuffer!
    private var vortexBuf: MTLBuffer!
    private var vortexCount = 0

    // two field frames + arrival times, blended in the advect kernel
    private var fieldTex: [MTLTexture] = []
    private var curIdx = 0
    private var fieldW = 0
    private var fieldH = 0
    private var tPrev: CFTimeInterval = 0
    private var tCurr: CFTimeInterval = 0

    private var trailTex: MTLTexture!
    private var trailNeedsClear = true

    private var params = Params()
    private var lastTime: CFTimeInterval = 0

    // ---- incoming frames (written on the network queue) --------------------
    private let fieldLock = NSLock()
    private var pendingField: (w: Int, h: Int, field: Data, vcount: Int, vdata: Data)?

    // ------------------------------------------------------------------------
    init(view: MTKView, device: MTLDevice) throws {
        self.device = device
        self.colorPixelFormat = view.colorPixelFormat
        guard let q = device.makeCommandQueue() else { throw Rerr("makeCommandQueue failed") }
        self.queue = q
        super.init()

        try buildPipelines()
        buildParticles()
        vortexBuf = device.makeBuffer(length: maxVortices * 3 * MemoryLayout<Float>.stride,
                                      options: .storageModeShared)
        buildFieldTextures(w: gridFallback, h: gridFallback)

        params.count = UInt32(particleCount)
        params.lifeMin = lifeMin
        params.lifeMax = lifeMax
    }

    struct Rerr: Error { let msg: String; init(_ m: String) { msg = m } }

    // ---- keyboard tuning (mirrors the panel) -------------------------------
    func handleKey(_ s: String) {
        switch s {
        case "]": fade = min(fade + 0.01, 0.40)
        case "[": fade = max(fade - 0.01, 0.01)
        case "=", "+": speed = min(speed + 0.05, 3.0)
        case "-", "_": speed = max(speed - 0.05, 0.0)
        case ".": pointSize = min(pointSize + 0.1, 4.0)
        case ",": pointSize = max(pointSize - 0.1, 0.5)
        case "1": setParticleCount(250_000)
        case "2": setParticleCount(500_000)
        case "3": setParticleCount(750_000)
        case "4": setParticleCount(1_000_000)
        case "v", "V": showVortices.toggle()
        case "r", "R": trailNeedsClear = true
        default: return
        }
        emitStatus()
    }

    func emitStatus() { onStatus?(statusLine()) }

    private func statusLine() -> String {
        let n = particleCount >= 1000 ? "\(particleCount / 1000)k" : "\(particleCount)"
        return String(format: "speed %.2f · fade %.3f · size %.1f · N %@", speed, fade, pointSize, n)
    }

    // ---- control-panel API -------------------------------------------------
    var currentSpeed: Float { speed }
    var currentFade: Float { fade }
    var currentPointSize: Float { pointSize }
    var currentParticleCount: Int { particleCount }

    func setSpeed(_ v: Float) { speed = v; emitStatus() }
    func setFade(_ v: Float) { fade = v; emitStatus() }
    func setPointSize(_ v: Float) { pointSize = v; emitStatus() }
    func setParticles(_ n: Int) { setParticleCount(n); emitStatus() }
    func setShowVortices(_ b: Bool) { showVortices = b }
    func resetParticles() { buildParticles(); trailNeedsClear = true }
    func resetTrail() { trailNeedsClear = true }

    private func setParticleCount(_ n: Int) {
        particleCount = n
        buildParticles()
        params.count = UInt32(n)
        trailNeedsClear = true
    }

    // ---- pipeline construction ---------------------------------------------
    private func buildPipelines() throws {
        let lib = try device.makeLibrary(source: shaderSource, options: nil)

        advectPSO = try device.makeComputePipelineState(function: lib.makeFunction(name: "advect")!)

        // particle points -> HDR trail (additive)
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = lib.makeFunction(name: "point_vertex")
        pd.fragmentFunction = lib.makeFunction(name: "point_fragment")
        configureAdditive(pd.colorAttachments[0]!, format: .rgba16Float)
        pointPSO = try device.makeRenderPipelineState(descriptor: pd)

        // fade quad -> multiplies trail by (1 - fade)
        let fd = MTLRenderPipelineDescriptor()
        fd.vertexFunction = lib.makeFunction(name: "fs_vertex")
        fd.fragmentFunction = lib.makeFunction(name: "fade_fragment")
        let fa = fd.colorAttachments[0]!
        fa.pixelFormat = .rgba16Float
        fa.isBlendingEnabled = true
        fa.rgbBlendOperation = .add
        fa.alphaBlendOperation = .add
        fa.sourceRGBBlendFactor = .zero
        fa.sourceAlphaBlendFactor = .zero
        fa.destinationRGBBlendFactor = .oneMinusSourceAlpha
        fa.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        fadePSO = try device.makeRenderPipelineState(descriptor: fd)

        // present: tonemap trail -> drawable
        let sd = MTLRenderPipelineDescriptor()
        sd.vertexFunction = lib.makeFunction(name: "fs_vertex")
        sd.fragmentFunction = lib.makeFunction(name: "present_fragment")
        sd.colorAttachments[0].pixelFormat = colorPixelFormat
        presentPSO = try device.makeRenderPipelineState(descriptor: sd)

        // vortex markers -> drawable (additive glow, drawn after present)
        let md = MTLRenderPipelineDescriptor()
        md.vertexFunction = lib.makeFunction(name: "marker_vertex")
        md.fragmentFunction = lib.makeFunction(name: "marker_fragment")
        configureAdditive(md.colorAttachments[0]!, format: colorPixelFormat)
        markerPSO = try device.makeRenderPipelineState(descriptor: md)
    }

    private func configureAdditive(_ a: MTLRenderPipelineColorAttachmentDescriptor,
                                   format: MTLPixelFormat) {
        a.pixelFormat = format
        a.isBlendingEnabled = true
        a.rgbBlendOperation = .add
        a.alphaBlendOperation = .add
        a.sourceRGBBlendFactor = .one
        a.sourceAlphaBlendFactor = .one
        a.destinationRGBBlendFactor = .one
        a.destinationAlphaBlendFactor = .one
    }

    // ---- particle buffers --------------------------------------------------
    private func buildParticles() {
        var pos = [SIMD2<Float>](repeating: .zero, count: particleCount)
        var life = [Float](repeating: 0, count: particleCount)
        var seed = SystemRandomNumberGenerator()
        for i in 0..<particleCount {
            pos[i] = SIMD2<Float>(Float.random(in: -1...1, using: &seed),
                                  Float.random(in: -1...1, using: &seed))
            life[i] = Float.random(in: lifeMin...lifeMax, using: &seed)
        }
        posBuf = device.makeBuffer(bytes: &pos,
                                   length: MemoryLayout<SIMD2<Float>>.stride * particleCount,
                                   options: .storageModeShared)
        lifeBuf = device.makeBuffer(bytes: &life,
                                    length: MemoryLayout<Float>.stride * particleCount,
                                    options: .storageModeShared)
        spdBuf = device.makeBuffer(length: MemoryLayout<Float>.stride * particleCount,
                                   options: .storageModeShared)
    }

    // ---- textures ----------------------------------------------------------
    private func buildFieldTextures(w: Int, h: Int) {
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rg32Float, width: w, height: h, mipmapped: false)
        d.usage = .shaderRead
        d.storageMode = .shared
        fieldTex = [device.makeTexture(descriptor: d)!, device.makeTexture(descriptor: d)!]
        fieldW = w; fieldH = h
        let zeros = [Float](repeating: 0, count: w * h * 2)
        for t in fieldTex {
            t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                      withBytes: zeros, bytesPerRow: w * 2 * MemoryLayout<Float>.size)
        }
        curIdx = 0
        tPrev = CACurrentMediaTime(); tCurr = tPrev
    }

    private func uploadField(_ tex: MTLTexture, _ data: Data, _ w: Int, _ h: Int) {
        data.withUnsafeBytes { raw in
            tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                        withBytes: raw.baseAddress!, bytesPerRow: w * 2 * MemoryLayout<Float>.size)
        }
    }

    private func buildTrailTexture(width: Int, height: Int) {
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: max(width, 1), height: max(height, 1),
            mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        trailTex = device.makeTexture(descriptor: d)
        trailNeedsClear = true
    }

    // ---- frame update (called from the network queue) ----------------------
    func updateField(w: Int, h: Int, field: Data, vortexCount: Int, vortexBytes: Data) {
        fieldLock.lock()
        pendingField = (w, h, field, vortexCount, vortexBytes)
        fieldLock.unlock()
    }

    private func consumePendingField() {
        fieldLock.lock()
        let pending = pendingField
        pendingField = nil
        fieldLock.unlock()
        guard let p = pending else { return }

        let now = CACurrentMediaTime()

        if p.w != fieldW || p.h != fieldH {
            // resize: both frames become the new field, no blend across the change
            buildFieldTextures(w: p.w, h: p.h)
            uploadField(fieldTex[0], p.field, p.w, p.h)
            uploadField(fieldTex[1], p.field, p.w, p.h)
            tPrev = now; tCurr = now
        } else {
            curIdx ^= 1                       // newest becomes current, old becomes previous
            uploadField(fieldTex[curIdx], p.field, p.w, p.h)
            tPrev = tCurr; tCurr = now
        }

        // vortex markers
        let n = min(p.vcount, maxVortices)
        vortexCount = n
        if n > 0 {
            p.vdata.withUnsafeBytes { raw in
                memcpy(vortexBuf.contents(), raw.baseAddress!, n * 3 * MemoryLayout<Float>.stride)
            }
        }
    }

    // ---- MTKViewDelegate ---------------------------------------------------
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        buildTrailTexture(width: Int(size.width), height: Int(size.height))
    }

    func draw(in view: MTKView) {
        guard let trailTex,
              let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer() else { return }

        let now = CACurrentMediaTime()
        var dt = lastTime == 0 ? 1.0 / 60.0 : Float(now - lastTime)
        lastTime = now
        dt = min(max(dt, 0), 1.0 / 30.0)

        params.dt = dt
        params.frame &+= 1
        params.speed = speed
        params.pointSize = pointSize
        params.fade = fade
        params.count = UInt32(particleCount)

        let W = Float(view.drawableSize.width), H = Float(view.drawableSize.height)
        params.aspect = W > H ? SIMD2<Float>(H / W, 1) : SIMD2<Float>(1, W / H)

        consumePendingField()

        // temporal blend factor between the two most recent field frames
        let interval = tCurr - tPrev
        params.alpha = interval > 0 ? Float(min(max((now - tCurr) / interval, 0), 1)) : 1
        let prevIdx = curIdx ^ 1

        // 1) advect particles through the interpolated field
        if let ce = cmd.makeComputeCommandEncoder() {
            ce.setComputePipelineState(advectPSO)
            ce.setBuffer(posBuf, offset: 0, index: 0)
            ce.setBuffer(lifeBuf, offset: 0, index: 1)
            ce.setBuffer(spdBuf, offset: 0, index: 2)
            ce.setBytes(&params, length: MemoryLayout<Params>.stride, index: 3)
            ce.setTexture(fieldTex[prevIdx], index: 0)
            ce.setTexture(fieldTex[curIdx], index: 1)
            let tpg = MTLSize(width: 256, height: 1, depth: 1)
            let grid = MTLSize(width: particleCount, height: 1, depth: 1)
            ce.dispatchThreads(grid, threadsPerThreadgroup: tpg)
            ce.endEncoding()
        }

        // 2) trail pass: fade existing, then additively draw points
        let trailPass = MTLRenderPassDescriptor()
        trailPass.colorAttachments[0].texture = trailTex
        trailPass.colorAttachments[0].loadAction = trailNeedsClear ? .clear : .load
        trailPass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        trailPass.colorAttachments[0].storeAction = .store
        trailNeedsClear = false

        if let re = cmd.makeRenderCommandEncoder(descriptor: trailPass) {
            re.setRenderPipelineState(fadePSO)
            re.setFragmentBytes(&params, length: MemoryLayout<Params>.stride, index: 0)
            re.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

            re.setRenderPipelineState(pointPSO)
            re.setVertexBuffer(posBuf, offset: 0, index: 0)
            re.setVertexBuffer(lifeBuf, offset: 0, index: 1)
            re.setVertexBuffer(spdBuf, offset: 0, index: 2)
            re.setVertexBytes(&params, length: MemoryLayout<Params>.stride, index: 3)
            re.drawPrimitives(type: .point, vertexStart: 0, vertexCount: particleCount)
            re.endEncoding()
        }

        // 3) present: tonemap trail -> drawable
        if let rp = view.currentRenderPassDescriptor {
            rp.colorAttachments[0].loadAction = .dontCare
            if let pe = cmd.makeRenderCommandEncoder(descriptor: rp) {
                pe.setRenderPipelineState(presentPSO)
                pe.setFragmentTexture(trailTex, index: 0)
                pe.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                pe.endEncoding()
            }
        }

        // 4) vortex markers -> drawable (glow on top)
        if showVortices && vortexCount > 0 {
            let mp = MTLRenderPassDescriptor()
            mp.colorAttachments[0].texture = drawable.texture
            mp.colorAttachments[0].loadAction = .load
            mp.colorAttachments[0].storeAction = .store
            if let me = cmd.makeRenderCommandEncoder(descriptor: mp) {
                me.setRenderPipelineState(markerPSO)
                me.setVertexBuffer(vortexBuf, offset: 0, index: 0)
                me.setVertexBytes(&params, length: MemoryLayout<Params>.stride, index: 1)
                me.drawPrimitives(type: .point, vertexStart: 0, vertexCount: vortexCount)
                me.endEncoding()
            }
        }

        cmd.present(drawable)
        cmd.commit()
    }
}
