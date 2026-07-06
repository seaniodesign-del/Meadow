import MetalKit
import os.log

/// MTKViewDelegate that runs on the main thread.
/// Physics updates and rendering are both driven by MTKView's internal loop,
/// so viewModel (also @MainActor) can be accessed directly with no actor-hopping.
@MainActor
final class GrassRenderer: NSObject, MTKViewDelegate, TouchForwarder {

    // MARK: - Dependencies
    private let viewModel: GrassFieldViewModel
    private weak var mtkView: TouchMTKView?

    // MARK: - Metal core
    private var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?

    // MARK: - Pipeline states
    private var bladePipelineState:         MTLRenderPipelineState?
    private var shadowPipelineState:        MTLRenderPipelineState?
    private var leaf3DPipelineState:        MTLRenderPipelineState?
    private var leaf3DShadowPipelineState:  MTLRenderPipelineState?
    private var dandelionMeshPipelineState:       MTLRenderPipelineState?
    private var dandelionMeshShadowPipelineState: MTLRenderPipelineState?

    // MARK: - Buffers
    private var bladeVertexBuffer:    MTLBuffer?
    private var instanceBuffer:       MTLBuffer?
    private var instanceCount:        Int = 0
    private var lastKnownFieldVersion: Int = -1

    private var leafTextureArray:       MTLTexture?
    // Per-species 3-D mesh buffers (7 species matching LeafMesh.allVertices/allIndices).
    private var leafMeshVertexBuffers:   [MTLBuffer?] = Array(repeating: nil, count: 7)
    private var leafMeshIndexBuffers:    [MTLBuffer?] = Array(repeating: nil, count: 7)
    private var leafMeshIndexCounts:     [Int]         = Array(repeating: 0,   count: 7)
    // Per-species instance buffers: [floor instances][air instances] per species.
    private var leafSpeciesInstanceBufs: [MTLBuffer?] = Array(repeating: nil, count: 7)
    private var leafSpeciesFloorCounts:  [Int]         = Array(repeating: 0,   count: 7)
    private var leafSpeciesAirCounts:    [Int]         = Array(repeating: 0,   count: 7)

    private var dandelionInstanceBuffer: MTLBuffer?
    private var dandelionCount:          Int = 0

    // MARK: - Dandelion 3-D mesh buffers (built once from DandelionMesh.swift)
    private var dandelionMeshStemVertexBuf:   MTLBuffer?
    private var dandelionMeshStemIndexBuf:    MTLBuffer?
    private var dandelionMeshStemIndexCount:  Int = 0

    private var dandelionMeshPuffVertexBuf:   MTLBuffer?
    private var dandelionMeshPuffIndexBuf:    MTLBuffer?
    private var dandelionMeshPuffIndexCount:  Int = 0

    private var dandelionMeshCentreVertexBuf:  MTLBuffer?
    private var dandelionMeshCentreIndexBuf:   MTLBuffer?
    private var dandelionMeshCentreIndexCount: Int = 0

    // MARK: - Tree shadow mask
    /// CPU-rendered shadow silhouette uploaded to a ¼-res .r8Unorm texture.
    /// Sampled by `grassFragment` to darken blades inside the tree shadow.
    private let shadowMask = GrassShadowMask()
    /// 1×1 black .r8Unorm texture used as a safe fallback so the blade pipeline's
    /// [[texture(0)]] slot is always bound with the correct type — even on the first
    /// frame before the real shadow mask is ready, and even after leaf passes that
    /// leave a texture2d_array at that slot (which would cause a type-mismatch abort).
    private var shadowFallbackTexture: (any MTLTexture)?

    // MARK: - Frame timing
    private var lastFrameTime: CFTimeInterval = 0
    private var drawCallCount: Int = 0
    private var elapsedTime: Float = 0          // cumulative seconds, drives wind shader

    // MARK: - Logging
    private let log = Logger(subsystem: "com.meadow.app", category: "GrassRenderer")

    // MARK: - Init
    init(viewModel: GrassFieldViewModel) {
        self.viewModel = viewModel
        super.init()
    }

    func setup(device: MTLDevice, view: TouchMTKView) {
        self.device = device
        self.mtkView = view
        commandQueue = device.makeCommandQueue()
        log.info("GrassRenderer.setup — building pipelines, pixel format: \(view.colorPixelFormat.rawValue)")
        buildPipelineStates(device: device, pixelFormat: view.colorPixelFormat)
        buildBladeVertexBuffer(device: device)
        buildLeafTextureArray(device: device)
        buildDandelionMeshBuffers(device: device)
        buildShadowFallbackTexture(device: device)
        buildLeafMeshBuffers(device: device)
        // Wire haptic generators to this view so iOS 17.5+ can route feedback
        // through the correct UIWindowScene (view-less inits silently fail).
        viewModel.setupHapticGenerators(view: view)
        // Ensure loop is armed even if didMoveToWindow fires before setup completes
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        log.info("GrassRenderer.setup complete — isPaused=\(view.isPaused)")
    }

    // MARK: - Leaf Texture Array

    private func buildLeafTextureArray(device: MTLDevice) {
        let sliceCount = 7
        let size       = 1024

        let desc            = MTLTextureDescriptor()
        desc.textureType    = .type2DArray
        desc.pixelFormat    = .rgba8Unorm
        desc.width          = size
        desc.height         = size
        desc.arrayLength    = sliceCount
        desc.usage          = .shaderRead
        desc.storageMode    = .shared   // CPU-writable so we can replaceRegion

        guard let arrayTex = device.makeTexture(descriptor: desc) else {
            log.error("buildLeafTextureArray: makeTexture failed")
            return
        }

        // A single CGContext we reuse for each image → raw RGBA bytes.
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let ctx = CGContext(data: nil, width: size, height: size,
                                  bitsPerComponent: 8, bytesPerRow: size * 4,
                                  space: colorSpace, bitmapInfo: bitmapInfo.rawValue) else {
            log.error("buildLeafTextureArray: CGContext creation failed")
            return
        }

        var loadedCount = 0
        for i in 0..<sliceCount {
            guard
                let url     = Bundle.main.url(forResource: "leaf_\(i)", withExtension: "png"),
                let data    = try? Data(contentsOf: url),
                let uiImage = UIImage(data: data),
                let cgImage = uiImage.cgImage
            else {
                log.warning("buildLeafTextureArray: leaf_\(i).png not found or unloadable")
                continue
            }

            ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))

            guard let bytes = ctx.data else { continue }

            arrayTex.replace(
                region:       MTLRegion(origin: .init(x: 0, y: 0, z: 0),
                                        size:   .init(width: size, height: size, depth: 1)),
                mipmapLevel:  0,
                slice:        i,
                withBytes:    bytes,
                bytesPerRow:  size * 4,
                bytesPerImage: size * size * 4
            )
            loadedCount += 1
        }

        leafTextureArray = arrayTex
        log.info("🍂 Leaf texture array: \(loadedCount)/\(sliceCount) slices loaded (\(size)×\(size))")
    }

    // MARK: - Dandelion Mesh Buffer Build

    /// Uploads the pre-decimated OBJ geometry (from DandelionMesh.swift) into
    /// static Metal buffers.  Called once during setup; the data never changes.
    private func buildDandelionMeshBuffers(device: MTLDevice) {
        func makeVtx(_ floats: [Float], label: String) -> MTLBuffer? {
            let len = floats.count * MemoryLayout<Float>.stride
            let buf = device.makeBuffer(bytes: floats, length: len, options: .storageModeShared)
            buf?.label = label
            return buf
        }
        func makeIdx(_ indices: [UInt16], label: String) -> MTLBuffer? {
            let len = indices.count * MemoryLayout<UInt16>.stride
            let buf = device.makeBuffer(bytes: indices, length: len, options: .storageModeShared)
            buf?.label = label
            return buf
        }

        dandelionMeshStemVertexBuf   = makeVtx(DandelionMesh.stemVertices,   label: "DandelionStemVerts")
        dandelionMeshStemIndexBuf    = makeIdx(DandelionMesh.stemIndices,     label: "DandelionStemIdx")
        dandelionMeshStemIndexCount  = DandelionMesh.stemIndices.count

        dandelionMeshPuffVertexBuf   = makeVtx(DandelionMesh.puffVertices,   label: "DandelionPuffVerts")
        dandelionMeshPuffIndexBuf    = makeIdx(DandelionMesh.puffIndices,     label: "DandelionPuffIdx")
        dandelionMeshPuffIndexCount  = DandelionMesh.puffIndices.count

        dandelionMeshCentreVertexBuf  = makeVtx(DandelionMesh.centreVertices, label: "DandelionCentreVerts")
        dandelionMeshCentreIndexBuf   = makeIdx(DandelionMesh.centreIndices,  label: "DandelionCentreIdx")
        dandelionMeshCentreIndexCount = DandelionMesh.centreIndices.count

        log.info("🌼 Dandelion mesh buffers built — stem \(DandelionMesh.stemIndices.count / 3) tris, puff \(DandelionMesh.puffIndices.count / 3) tris, centre \(DandelionMesh.centreIndices.count / 3) tris")
    }

    // MARK: - Pipeline Setup

    private func buildPipelineStates(device: MTLDevice, pixelFormat: MTLPixelFormat) {
        guard let library = device.makeDefaultLibrary() else {
            log.error("⚠️ GrassRenderer: makeDefaultLibrary() returned nil — no Metal library in bundle")
            return
        }
        let fnNames = library.functionNames.joined(separator: ", ")
        log.info("GrassRenderer: Metal library loaded — functions: \(fnNames)")

        guard
            let vertFn              = library.makeFunction(name: "grassVertex"),
            let bladeFn             = library.makeFunction(name: "grassFragment"),
            let shadowFn            = library.makeFunction(name: "grassShadowFragment"),
            let leaf3DVertFn        = library.makeFunction(name: "leaf3DVertex"),
            let leaf3DFragFn        = library.makeFunction(name: "leaf3DFragment"),
            let leaf3DShadowFragFn  = library.makeFunction(name: "leaf3DShadowFragment"),
            let dandelionMeshVertFn       = library.makeFunction(name: "dandelionMeshVertex"),
            let dandelionMeshFragFn       = library.makeFunction(name: "dandelionMeshFragment"),
            let dandelionMeshShadowFragFn = library.makeFunction(name: "dandelionMeshShadowFragment")
        else {
            log.error("⚠️ GrassRenderer: shader function(s) not found in library")
            return
        }

        // Vertex descriptor — matches VertexIn in GrassShaders.metal
        let vd = MTLVertexDescriptor()
        vd.attributes[0].format      = .float2
        vd.attributes[0].offset      = 0
        vd.attributes[0].bufferIndex = 0
        vd.attributes[1].format      = .float
        vd.attributes[1].offset      = MemoryLayout<SIMD2<Float>>.stride   // = 8
        vd.attributes[1].bufferIndex = 0
        vd.layouts[0].stride         = MemoryLayout<BladeVertex>.stride    // = 12

        // Blade pipeline — opaque
        let bd = MTLRenderPipelineDescriptor()
        bd.label                           = "GrassBlade"
        bd.vertexFunction                  = vertFn
        bd.fragmentFunction                = bladeFn
        bd.vertexDescriptor                = vd
        bd.colorAttachments[0].pixelFormat = pixelFormat

        // Shadow pipeline — alpha-blended, rendered before blades
        let sd = MTLRenderPipelineDescriptor()
        sd.label                           = "GrassShadow"
        sd.vertexFunction                  = vertFn
        sd.fragmentFunction                = shadowFn
        sd.vertexDescriptor                = vd
        let sca                            = sd.colorAttachments[0]!
        sca.pixelFormat                    = pixelFormat
        sca.isBlendingEnabled              = true
        sca.rgbBlendOperation              = .add
        sca.alphaBlendOperation            = .add
        sca.sourceRGBBlendFactor           = .sourceAlpha
        sca.destinationRGBBlendFactor      = .oneMinusSourceAlpha
        sca.sourceAlphaBlendFactor         = .one
        sca.destinationAlphaBlendFactor    = .oneMinusSourceAlpha

        // Leaf 3-D mesh vertex descriptor: pos(float3,0) + normal(float3,12) + uv(float2,24), stride 32
        let leafMeshVD = MTLVertexDescriptor()
        leafMeshVD.attributes[0].format      = .float3
        leafMeshVD.attributes[0].offset      = 0
        leafMeshVD.attributes[0].bufferIndex = 0
        leafMeshVD.attributes[1].format      = .float3
        leafMeshVD.attributes[1].offset      = 12
        leafMeshVD.attributes[1].bufferIndex = 0
        leafMeshVD.attributes[2].format      = .float2
        leafMeshVD.attributes[2].offset      = 24
        leafMeshVD.attributes[2].bufferIndex = 0
        leafMeshVD.layouts[0].stride         = 32

        let l3d = MTLRenderPipelineDescriptor()
        l3d.label                           = "Leaf3D"
        l3d.vertexFunction                  = leaf3DVertFn
        l3d.fragmentFunction                = leaf3DFragFn
        l3d.vertexDescriptor                = leafMeshVD
        let l3dca                           = l3d.colorAttachments[0]!
        l3dca.pixelFormat                   = pixelFormat
        l3dca.isBlendingEnabled             = true
        l3dca.rgbBlendOperation             = .add
        l3dca.alphaBlendOperation           = .add
        l3dca.sourceRGBBlendFactor          = .sourceAlpha
        l3dca.destinationRGBBlendFactor     = .oneMinusSourceAlpha
        l3dca.sourceAlphaBlendFactor        = .one
        l3dca.destinationAlphaBlendFactor   = .oneMinusSourceAlpha

        let l3ds = MTLRenderPipelineDescriptor()
        l3ds.label                          = "Leaf3DShadow"
        l3ds.vertexFunction                 = leaf3DVertFn
        l3ds.fragmentFunction               = leaf3DShadowFragFn
        l3ds.vertexDescriptor               = leafMeshVD
        let l3dsca                          = l3ds.colorAttachments[0]!
        l3dsca.pixelFormat                  = pixelFormat
        l3dsca.isBlendingEnabled            = true
        l3dsca.rgbBlendOperation            = .add
        l3dsca.alphaBlendOperation          = .add
        l3dsca.sourceRGBBlendFactor         = .sourceAlpha
        l3dsca.destinationRGBBlendFactor    = .oneMinusSourceAlpha
        l3dsca.sourceAlphaBlendFactor       = .one
        l3dsca.destinationAlphaBlendFactor  = .oneMinusSourceAlpha

        // Dandelion 3-D mesh — vertex layout: float3 position + float3 normal (stride 24)
        // Alpha-blended so the root fade and any transparent parts composite correctly.
        let meshVD = MTLVertexDescriptor()
        meshVD.attributes[0].format      = .float3   // position  (offset  0)
        meshVD.attributes[0].offset      = 0
        meshVD.attributes[0].bufferIndex = 0
        meshVD.attributes[1].format      = .float3   // normal    (offset 12)
        meshVD.attributes[1].offset      = 12
        meshVD.attributes[1].bufferIndex = 0
        meshVD.layouts[0].stride         = 24        // 6 × Float32

        let dmd = MTLRenderPipelineDescriptor()
        dmd.label                          = "DandelionMesh"
        dmd.vertexFunction                 = dandelionMeshVertFn
        dmd.fragmentFunction               = dandelionMeshFragFn
        dmd.vertexDescriptor               = meshVD
        let dmca                           = dmd.colorAttachments[0]!
        dmca.pixelFormat                   = pixelFormat
        dmca.isBlendingEnabled             = true
        dmca.rgbBlendOperation             = .add
        dmca.alphaBlendOperation           = .add
        dmca.sourceRGBBlendFactor          = .sourceAlpha
        dmca.destinationRGBBlendFactor     = .oneMinusSourceAlpha
        dmca.sourceAlphaBlendFactor        = .one
        dmca.destinationAlphaBlendFactor   = .oneMinusSourceAlpha

        // Dandelion shadow — same vertex shader (shadowSlantX > 0 in uniforms flattens
        // each vertex onto the ground), dark semi-transparent shadow fragment.
        let dmsd = MTLRenderPipelineDescriptor()
        dmsd.label                          = "DandelionMeshShadow"
        dmsd.vertexFunction                 = dandelionMeshVertFn
        dmsd.fragmentFunction               = dandelionMeshShadowFragFn
        dmsd.vertexDescriptor               = meshVD
        let dmsca                           = dmsd.colorAttachments[0]!
        dmsca.pixelFormat                   = pixelFormat
        dmsca.isBlendingEnabled             = true
        dmsca.rgbBlendOperation             = .add
        dmsca.alphaBlendOperation           = .add
        dmsca.sourceRGBBlendFactor          = .sourceAlpha
        dmsca.destinationRGBBlendFactor     = .oneMinusSourceAlpha
        dmsca.sourceAlphaBlendFactor        = .one
        dmsca.destinationAlphaBlendFactor   = .oneMinusSourceAlpha

        do {
            bladePipelineState                = try device.makeRenderPipelineState(descriptor: bd)
            shadowPipelineState               = try device.makeRenderPipelineState(descriptor: sd)
            leaf3DPipelineState               = try device.makeRenderPipelineState(descriptor: l3d)
            leaf3DShadowPipelineState         = try device.makeRenderPipelineState(descriptor: l3ds)
            dandelionMeshPipelineState        = try device.makeRenderPipelineState(descriptor: dmd)
            dandelionMeshShadowPipelineState  = try device.makeRenderPipelineState(descriptor: dmsd)
            log.info("✅ GrassRenderer: pipelines built successfully")
        } catch {
            log.error("⚠️ GrassRenderer: pipeline creation failed — \(error)")
        }
    }

    // MARK: - Blade Vertex Buffer (shared quad, triangle strip)

    private func buildBladeVertexBuffer(device: MTLDevice) {
        let verts: [BladeVertex] = [
            BladeVertex(position: SIMD2(-0.5,  0.0), normalizedHeight: 0.0),
            BladeVertex(position: SIMD2( 0.5,  0.0), normalizedHeight: 0.0),
            BladeVertex(position: SIMD2(-0.5,  1.0), normalizedHeight: 1.0),
            BladeVertex(position: SIMD2( 0.5,  1.0), normalizedHeight: 1.0),
        ]
        let len = MemoryLayout<BladeVertex>.stride * verts.count
        bladeVertexBuffer       = device.makeBuffer(bytes: verts, length: len, options: .storageModeShared)
        bladeVertexBuffer?.label = "BladeQuad"
    }

    // MARK: - Shadow fallback texture

    /// Creates a 1×1 black .r8Unorm texture.
    /// Bound to [[texture(0)]] whenever the real shadow mask isn't available yet,
    /// ensuring the slot always holds the correct texture type for `grassFragment`.
    private func buildShadowFallbackTexture(device: MTLDevice) {
        let desc         = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: 1, height: 1, mipmapped: false)
        desc.usage       = [.shaderRead]
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { return }
        var zero: UInt8 = 0
        tex.replace(
            region:      MTLRegion(origin: .init(x: 0, y: 0, z: 0),
                                   size:   .init(width: 1, height: 1, depth: 1)),
            mipmapLevel: 0,
            withBytes:   &zero,
            bytesPerRow: 1
        )
        tex.label = "ShadowFallback"
        shadowFallbackTexture = tex
    }

    // MARK: - Leaf 3-D Mesh Buffers

    private func buildLeafMeshBuffers(device: MTLDevice) {
        for i in 0..<7 {
            let verts   = LeafMesh.allVertices[i]
            let indices = LeafMesh.allIndices[i]
            let vLen    = verts.count   * MemoryLayout<Float>.stride
            let iLen    = indices.count * MemoryLayout<UInt16>.stride
            leafMeshVertexBuffers[i]        = device.makeBuffer(bytes: verts,   length: vLen, options: .storageModeShared)
            leafMeshVertexBuffers[i]?.label = "LeafMeshVerts_\(i)"
            leafMeshIndexBuffers[i]         = device.makeBuffer(bytes: indices, length: iLen, options: .storageModeShared)
            leafMeshIndexBuffers[i]?.label  = "LeafMeshIdx_\(i)"
            leafMeshIndexCounts[i]          = indices.count
        }
        let triCounts = LeafMesh.allIndices.indices.map { "\($0)=\(LeafMesh.allIndices[$0].count / 3)tri" }.joined(separator: " ")
        log.info("🍂 Leaf 3D mesh buffers — \(triCounts)")
    }

    // MARK: - Instance Buffer

    private func rebuildInstanceBuffer() {
        guard let device else {
            log.error("rebuildInstanceBuffer: no device")
            return
        }
        let blades = viewModel.blades
        guard !blades.isEmpty else {
            if lastKnownFieldVersion != -2 {
                log.info("rebuildInstanceBuffer: blades array still empty, waiting…")
                lastKnownFieldVersion = -2
            }
            return
        }
        let instances = blades.map { $0.instanceData() }
        let bytes     = MemoryLayout<BladeInstanceData>.stride * instances.count
        instanceBuffer       = device.makeBuffer(bytes: instances, length: bytes, options: .storageModeShared)
        instanceBuffer?.label = "GrassInstances"
        instanceCount         = instances.count
        lastKnownFieldVersion = viewModel.fieldVersion
        log.info("🌿 GrassRenderer: instance buffer built — \(self.instanceCount) blades, \(bytes) bytes")
    }

    // MARK: - MTKViewDelegate  (called on main thread by MTKView's internal loop)

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        viewModel.screenSize = view.bounds.size
    }

    func draw(in view: MTKView) {
        // ── Physics update ───────────────────────────────────────────────────
        let now   = CACurrentMediaTime()
        let delta = lastFrameTime == 0 ? 0 : Float(min(now - lastFrameTime, 0.033))
        lastFrameTime = now
        elapsedTime  += delta
        viewModel.update(deltaTime: delta, screenSize: view.bounds.size)

        // ── Sync grass instance buffer ───────────────────────────────────────
        if viewModel.fieldVersion != lastKnownFieldVersion {
            // Field was regenerated (new positions, possibly same count) — rebuild.
            rebuildInstanceBuffer()
        } else if let buf = instanceBuffer, instanceCount > 0 {
            // Touch bends changed — patch only the bendAngle field in-place.
            // The buffer uses .storageModeShared so the CPU can write directly.
            let bends = viewModel.touchBendAngles
            let ptr   = buf.contents().bindMemory(to: BladeInstanceData.self,
                                                   capacity: instanceCount)
            let count = min(instanceCount, bends.count)
            for i in 0..<count {
                ptr[i].bendAngle = bends[i]
            }
        }

        // ── Sync 3-D leaf per-species instance buffers ────────────────────────────────
        if let leafSystem = viewModel.leafSystem {
            let leafData  = leafSystem.instanceData
            let floorEnd  = leafSystem.floorLeafCount
            var floorBySpecies = Array(repeating: [LeafInstanceData](), count: 7)
            var airBySpecies   = Array(repeating: [LeafInstanceData](), count: 7)
            for i in 0..<floorEnd         { floorBySpecies[Int(leafData[i].textureIndex) % 7].append(leafData[i]) }
            for i in floorEnd..<leafData.count { airBySpecies[Int(leafData[i].textureIndex) % 7].append(leafData[i]) }
            for sp in 0..<7 {
                leafSpeciesFloorCounts[sp] = floorBySpecies[sp].count
                leafSpeciesAirCounts[sp]   = airBySpecies[sp].count
                let combined = floorBySpecies[sp] + airBySpecies[sp]
                guard !combined.isEmpty else { leafSpeciesInstanceBufs[sp] = nil; continue }
                let bytes = MemoryLayout<LeafInstanceData>.stride * combined.count
                if let buf = leafSpeciesInstanceBufs[sp], buf.length >= bytes {
                    buf.contents().copyMemory(from: combined, byteCount: bytes)
                } else {
                    leafSpeciesInstanceBufs[sp]        = device?.makeBuffer(bytes: combined, length: bytes, options: .storageModeShared)
                    leafSpeciesInstanceBufs[sp]?.label = "LeafInst_\(sp)"
                }
            }
        } else {
            for sp in 0..<7 { leafSpeciesFloorCounts[sp] = 0; leafSpeciesAirCounts[sp] = 0 }
        }

        // ── Sync dandelion instance buffer ────────────────────────────────────
        if let dandelionSystem = viewModel.dandelionSystem {
            let danData = dandelionSystem.instanceData
            let count   = danData.count
            if count > 0 {
                let bytes = MemoryLayout<DandelionInstanceData>.stride * count
                if let buf = dandelionInstanceBuffer, buf.length >= bytes,
                   count == dandelionCount {
                    buf.contents().copyMemory(from: danData, byteCount: bytes)
                } else {
                    dandelionInstanceBuffer = device?.makeBuffer(
                        bytes: danData, length: bytes, options: .storageModeShared)
                    dandelionInstanceBuffer?.label = "DandelionInstances"
                    dandelionCount = count
                }
            }
        } else {
            dandelionCount = 0
        }

        drawCallCount += 1

        // ── Guard all Metal objects ──────────────────────────────────────────
        guard
            let commandQueue,
            let bladePipelineState,
            let shadowPipelineState,
            let bladeVertexBuffer,
            let instanceBuffer,
            instanceCount > 0
        else {
            // Log only on first failed draw (blades are still loading)
            if drawCallCount == 1 {
                log.info("draw #1: waiting for blades — cq=\(self.commandQueue != nil) blade=\(self.bladePipelineState != nil) shadow=\(self.shadowPipelineState != nil) vtx=\(self.bladeVertexBuffer != nil) inst=\(self.instanceBuffer != nil) count=\(self.instanceCount) v=\(self.lastKnownFieldVersion)")
            }
            // Still no blades yet — render a plain clear-color frame
            if let descriptor = view.currentRenderPassDescriptor,
               let drawable   = view.currentDrawable,
               let cmd        = commandQueue?.makeCommandBuffer(),
               let enc        = cmd.makeRenderCommandEncoder(descriptor: descriptor) {
                enc.endEncoding()
                cmd.present(drawable)
                cmd.commit()
            }
            return
        }

        guard
            let descriptor = view.currentRenderPassDescriptor,
            let drawable   = view.currentDrawable,
            let cmd        = commandQueue.makeCommandBuffer(),
            let enc        = cmd.makeRenderCommandEncoder(descriptor: descriptor)
        else {
            log.warning("draw #\(self.drawCallCount): could not acquire drawable or command buffer")
            return
        }

        if drawCallCount == 1 {
            log.info("draw #1 with blades: rendering \(self.instanceCount) blades, bounds=\(view.bounds.size.width)×\(view.bounds.size.height)")
        }

        let size = SIMD2<Float>(Float(view.bounds.width), Float(view.bounds.height))

        // Update the tree-shadow mask texture (rebuilds only when time changes).
        if let device {
            shadowMask.update(timeOfDay: viewModel.settings.timeOfDay,
                              screenSize: view.bounds.size,
                              device: device)
        }

        // Wind amplitude: tiny ambient sway even with wind off, scaled by setting.
        let baseAmp: Float = 0.012
        let windAmp = baseAmp + viewModel.settings.windSpeed.amplitudeMultiplier * 0.15

        let todPalette = TimeOfDay.palette(
            for: viewModel.settings.timeOfDay,
            season: viewModel.settings.currentSeason
        )
        view.clearColor = todPalette.metalClearColor
        let todFloat = Float(viewModel.settings.timeOfDay)

        // Helper: draw one part of the 3-D dandelion mesh.
        // isShadow=true selects the shadow pipeline and activates the ground-projection
        // transform (shadowSlantX > 0) so every vertex is flattened onto rootPosition.y
        // with a sun-direction shear, producing a distorted silhouette shadow.
        func drawDandelionMeshPart(vertBuf: MTLBuffer, idxBuf: MTLBuffer,
                                   indexCount: Int, colour: SIMD4<Float>,
                                   isShadow: Bool = false) {
            guard dandelionCount > 0,
                  let danBuf = dandelionInstanceBuffer else { return }
            if isShadow {
                guard let dandelionMeshShadowPipelineState else { return }
                enc.setRenderPipelineState(dandelionMeshShadowPipelineState)
            } else {
                guard let dandelionMeshPipelineState else { return }
                enc.setRenderPipelineState(dandelionMeshPipelineState)
            }
            enc.setVertexBuffer(vertBuf, offset: 0, index: 0)
            enc.setVertexBuffer(danBuf,  offset: 0, index: 1)
            // Shadow slant: fixed 0.50 (≈ 45° sun elevation, rightward like leaf/grass shadows).
            // Colour pass: 0 — no displacement.
            let slant: Float = isShadow ? 0.50 : 0.0
            var vtxUni = DandelionVertexUniforms(screenSize: size, time: elapsedTime,
                                                 windAmplitude: windAmp,
                                                 timeOfDay: todFloat,
                                                 shadowSlantX: slant)
            enc.setVertexBytes(&vtxUni, length: MemoryLayout<DandelionVertexUniforms>.stride, index: 2)
            if !isShadow {
                var meshUni = DandelionMeshUniforms(colour: colour, timeOfDay: todFloat)
                enc.setFragmentBytes(&meshUni, length: MemoryLayout<DandelionMeshUniforms>.stride, index: 0)
            }
            enc.drawIndexedPrimitives(type: .triangle,
                                      indexCount: indexCount,
                                      indexType: .uint16,
                                      indexBuffer: idxBuf,
                                      indexBufferOffset: 0,
                                      instanceCount: dandelionCount)
        }

        // Helper: draw one group of 3-D leaf instances (colour or shadow).
        // `floorOnly` = true draws floor (resting) leaves; false draws air (falling) leaves.
        // `isShadow`  = true uses the shadow pipeline with ground projection.
        // `suppressWind` = pass windAmplitude=0 for resting leaves.
        func drawLeaves3D(floorOnly: Bool, isShadow: Bool, suppressWind: Bool = false) {
            guard let leafTex = leafTextureArray else { return }
            let pipeline: MTLRenderPipelineState?
            if isShadow { pipeline = leaf3DShadowPipelineState }
            else        { pipeline = leaf3DPipelineState }
            guard let pipeline else { return }

            let effectiveWind: Float = suppressWind ? 0 : windAmp
            var uni = LeafVertexUniforms(
                screenSize:    size,
                time:          elapsedTime,
                windAmplitude: effectiveWind,
                shadowOffset:  isShadow ? SIMD2(0.22, 1.0) : .zero
            )

            for sp in 0..<7 {
                guard let vtxBuf  = leafMeshVertexBuffers[sp],
                      let idxBuf  = leafMeshIndexBuffers[sp],
                      let instBuf = leafSpeciesInstanceBufs[sp] else { continue }
                let floorCount = leafSpeciesFloorCounts[sp]
                let airCount   = leafSpeciesAirCounts[sp]
                let (baseInst, instCount): (Int, Int) = floorOnly
                    ? (0, floorCount)
                    : (floorCount, airCount)
                guard instCount > 0 else { continue }

                enc.setRenderPipelineState(pipeline)
                enc.setVertexBuffer(vtxBuf,  offset: 0, index: 0)
                enc.setVertexBuffer(instBuf, offset: 0, index: 1)
                enc.setVertexBytes(&uni, length: MemoryLayout<LeafVertexUniforms>.stride, index: 2)
                enc.setFragmentTexture(leafTex, index: 0)

                var spIdx = UInt32(sp)
                if isShadow {
                    enc.setFragmentBytes(&spIdx, length: MemoryLayout<UInt32>.stride, index: 0)
                } else {
                    var todF = todFloat
                    enc.setFragmentBytes(&todF,  length: MemoryLayout<Float>.stride,   index: 0)
                    enc.setFragmentBytes(&spIdx, length: MemoryLayout<UInt32>.stride,   index: 1)
                }

                enc.drawIndexedPrimitives(
                    type:              .triangle,
                    indexCount:        leafMeshIndexCounts[sp],
                    indexType:         .uint16,
                    indexBuffer:       idxBuf,
                    indexBufferOffset: 0,
                    instanceCount:     instCount,
                    baseVertex:        0,
                    baseInstance:      baseInst
                )
            }
        }

        // ── Render order (painter's algorithm) ───────────────────────────────
        //  1. Floor leaf shadows      — under everything, occluded by grass blades
        //  2. Floor leaves            — nestled in the field, occluded by grass blades
        //  3. Grass shadow pass       — blade shadows on the ground
        //  4. Dandelion ground shadows — projected 3-D silhouettes in sun direction
        //  5. Dandelion stems (colour) — before grass blades so grass can occlude them
        //  6. Grass blade pass        — grass covers short dandelion stem bases
        //  7. Dandelion puffs + centres — float above the grass tips (3-D mesh)
        //  8. Air leaf shadows        — falling leaf shadows above the grass
        //  9. Air leaves              — falling leaves floating above the grass

        // ── 1. Floor leaf shadows ────────────────────────────────────────────
        drawLeaves3D(floorOnly: true, isShadow: true, suppressWind: true)

        // ── 2. Floor leaves ──────────────────────────────────────────────────
        drawLeaves3D(floorOnly: true, isShadow: false, suppressWind: true)

        // ── 3. Grass shadow pass ─────────────────────────────────────────────
        enc.setVertexBuffer(bladeVertexBuffer, offset: 0, index: 0)
        enc.setVertexBuffer(instanceBuffer,    offset: 0, index: 1)

        enc.setRenderPipelineState(shadowPipelineState)
        var shadowUni = GrassVertexUniforms(screenSize: size,
                                            positionOffset: SIMD2(5.0, 4.5),
                                            time: elapsedTime,
                                            windAmplitude: windAmp,
                                            timeOfDay: todFloat)
        enc.setVertexBytes(&shadowUni, length: MemoryLayout<GrassVertexUniforms>.stride, index: 2)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                           instanceCount: instanceCount)

        // ── 4. Dandelion ground shadows ──────────────────────────────────────
        // All three mesh parts projected onto rootPosition.y in sun direction.
        // Drawn before grass blades so the grass partially hides the shadows.
        if let vb = dandelionMeshStemVertexBuf,   let ib = dandelionMeshStemIndexBuf {
            drawDandelionMeshPart(vertBuf: vb, idxBuf: ib,
                                  indexCount: dandelionMeshStemIndexCount,
                                  colour: .zero, isShadow: true)
        }
        if let vb = dandelionMeshPuffVertexBuf,   let ib = dandelionMeshPuffIndexBuf {
            drawDandelionMeshPart(vertBuf: vb, idxBuf: ib,
                                  indexCount: dandelionMeshPuffIndexCount,
                                  colour: .zero, isShadow: true)
        }
        if let vb = dandelionMeshCentreVertexBuf, let ib = dandelionMeshCentreIndexBuf {
            drawDandelionMeshPart(vertBuf: vb, idxBuf: ib,
                                  indexCount: dandelionMeshCentreIndexCount,
                                  colour: .zero, isShadow: true)
        }

        // ── 5. Dandelion stems (colour) ──────────────────────────────────────
        if let vb = dandelionMeshStemVertexBuf, let ib = dandelionMeshStemIndexBuf {
            drawDandelionMeshPart(vertBuf: vb, idxBuf: ib,
                                  indexCount: dandelionMeshStemIndexCount,
                                  colour: DandelionMesh.stemColour)
        }

        // ── 5. Grass blade pass ──────────────────────────────────────────────
        enc.setVertexBuffer(bladeVertexBuffer, offset: 0, index: 0)
        enc.setVertexBuffer(instanceBuffer,    offset: 0, index: 1)
        enc.setRenderPipelineState(bladePipelineState)
        var bladeUni = GrassVertexUniforms(screenSize: size, positionOffset: .zero,
                                           time: elapsedTime, windAmplitude: windAmp,
                                           timeOfDay: todFloat)
        enc.setVertexBytes(&bladeUni, length: MemoryLayout<GrassVertexUniforms>.stride, index: 2)
        var frag = todPalette.fragmentUniforms
        frag.screenSize = size   // needed by grassFragment for shadow UV computation
        enc.setFragmentBytes(&frag, length: MemoryLayout<GrassFragmentUniforms>.stride, index: 0)
        // Always bind a texture2d<float> at slot 0 so grassFragment's [[texture(0)]]
        // argument is never unset or left as the wrong type (leaf passes bind a
        // texture2d_array at this slot, which would cause a Metal validation abort).
        enc.setFragmentTexture(shadowMask.texture ?? shadowFallbackTexture, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                           instanceCount: instanceCount)

        // ── 6. Dandelion puffs + yellow centre ──────────────────────────────
        if let vb = dandelionMeshPuffVertexBuf, let ib = dandelionMeshPuffIndexBuf {
            drawDandelionMeshPart(vertBuf: vb, idxBuf: ib,
                                  indexCount: dandelionMeshPuffIndexCount,
                                  colour: DandelionMesh.puffColour)
        }
        if let vb = dandelionMeshCentreVertexBuf, let ib = dandelionMeshCentreIndexBuf {
            drawDandelionMeshPart(vertBuf: vb, idxBuf: ib,
                                  indexCount: dandelionMeshCentreIndexCount,
                                  colour: DandelionMesh.centreColour)
        }

        // ── 7. Air leaf shadows ──────────────────────────────────────────────
        drawLeaves3D(floorOnly: false, isShadow: true)

        // ── 8. Air leaves ─────────────────────────────────────────────────────
        drawLeaves3D(floorOnly: false, isShadow: false)

        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    // MARK: - TouchForwarder

    func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let pts = touches.map { t in
            TouchPoint(id: ObjectIdentifier(t),
                       position: t.location(in: t.view),
                       velocity: .zero)
        }
        viewModel.touchesBegan(pts)
    }

    func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        let pts = touches.map { t -> TouchPoint in
            let curr = t.location(in: t.view)
            let prev = t.previousLocation(in: t.view)
            let dt: Double = 1.0 / 60.0
            let vel = CGVector(dx: (curr.x - prev.x) / dt,
                               dy: (curr.y - prev.y) / dt)
            return TouchPoint(id: ObjectIdentifier(t), position: curr, velocity: vel)
        }
        viewModel.touchesMoved(pts)
    }

    func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        viewModel.touchesEnded(Set(touches.map { ObjectIdentifier($0) }))
    }

    func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }
}
