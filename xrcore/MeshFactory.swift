import Metal

enum MeshKind: Int {
    case box = 0
    case sphere = 1
    case panel = 2
}

struct GPUMesh {
    let vertexBuffer: MTLBuffer
    let indexBuffer: MTLBuffer?   // nil -> non-indexed, draw vertexCount verts
    let vertexCount: Int
    let indexCount: Int
    let indexType: MTLIndexType
}

// Procedural geometry. All meshes share one interleaved vertex layout —
// pos(3) + normal(3) + uv(2), 32-byte stride — so a single pipeline vertex
// descriptor serves every mesh (UVs are zero for box/sphere).
// Winding: CCW viewed from outside; pipelines use frontFacing(.counterClockwise).
enum MeshFactory {

    static func makeMeshes(device: MTLDevice) -> [MeshKind: GPUMesh] {
        var meshes: [MeshKind: GPUMesh] = [:]
        meshes[.box] = makeBox(device: device)
        meshes[.sphere] = makeSphere(device: device)
        meshes[.panel] = makePanel(device: device)
        return meshes
    }

    private static func appendVert(_ data: inout [Float], _ p: SIMD3<Float>, _ n: SIMD3<Float>, _ uv: SIMD2<Float> = SIMD2<Float>(0, 0)) {
        data.append(contentsOf: [p.x, p.y, p.z, n.x, n.y, n.z, uv.x, uv.y])
    }

    private static func buildMesh(device: MTLDevice, _ data: [Float], vertexCount: Int) -> GPUMesh {
        let vb = device.makeBuffer(bytes: data, length: data.count * MemoryLayout<Float>.size, options: .storageModeShared)!
        return GPUMesh(vertexBuffer: vb, indexBuffer: nil, vertexCount: vertexCount, indexCount: 0, indexType: .uint32)
    }

    private static func makeBox(device: MTLDevice) -> GPUMesh {
        let f: [[Float]] = [
            // -Z
            [-0.5,-0.5,-0.5,  0.5,-0.5,-0.5,  0.5, 0.5,-0.5,
              0.5, 0.5,-0.5, -0.5, 0.5,-0.5, -0.5,-0.5,-0.5],
            // +Z
            [-0.5,-0.5, 0.5,  0.5,-0.5, 0.5,  0.5, 0.5, 0.5,
              0.5, 0.5, 0.5, -0.5, 0.5, 0.5, -0.5,-0.5, 0.5],
            // -X
            [-0.5, 0.5, 0.5, -0.5, 0.5,-0.5, -0.5,-0.5,-0.5,
             -0.5,-0.5,-0.5, -0.5,-0.5, 0.5, -0.5, 0.5, 0.5],
            // +X
            [ 0.5, 0.5,-0.5,  0.5, 0.5, 0.5,  0.5,-0.5, 0.5,
              0.5,-0.5, 0.5,  0.5,-0.5,-0.5,  0.5, 0.5,-0.5],
            // -Y
            [-0.5,-0.5,-0.5,  0.5,-0.5,-0.5,  0.5,-0.5, 0.5,
              0.5,-0.5, 0.5, -0.5,-0.5, 0.5, -0.5,-0.5,-0.5],
            // +Y
            [-0.5, 0.5, 0.5,  0.5, 0.5, 0.5,  0.5, 0.5,-0.5,
              0.5, 0.5,-0.5, -0.5, 0.5,-0.5, -0.5, 0.5, 0.5],
        ]
        let normals: [[Float]] = [
            [0, 0, -1], [0, 0, 1], [-1, 0, 0], [1, 0, 0], [0, -1, 0], [0, 1, 0],
        ]

        var data: [Float] = []
        data.reserveCapacity(36 * 8)
        for (i, face) in f.enumerated() {
            let n = SIMD3<Float>(normals[i][0], normals[i][1], normals[i][2])
            var v = 0
            while v < face.count {
                appendVert(&data, SIMD3<Float>(face[v], face[v + 1], face[v + 2]), n)
                v += 3
            }
        }
        return buildMesh(device: device, data, vertexCount: 36)
    }

    private static func makeSphere(device: MTLDevice) -> GPUMesh {
        // UV-sphere, rings x segments quads -> 6 verts per quad, CCW outside.
        let rings = 16
        let segs = 24

        func point(_ i: Int, _ j: Int) -> SIMD3<Float> {
            let phi = Float(i) / Float(rings) * Float.pi               // 0 (top) .. pi (bottom)
            let theta = Float(j) / Float(segs) * 2 * Float.pi
            let y = cos(phi)
            let r = sin(phi)
            return SIMD3<Float>(r * cos(theta), y, r * sin(theta))
        }

        var data: [Float] = []
        data.reserveCapacity(rings * segs * 6 * 8)
        for i in 0..<rings {
            for j in 0..<segs {
                let p00 = point(i, j)
                let p01 = point(i, j + 1)
                let p10 = point(i + 1, j)
                let p11 = point(i + 1, j + 1)
                // CCW triangles facing outward: (p00,p11,p10) and (p00,p01,p11)
                for p in [p00, p11, p10, p00, p01, p11] {
                    appendVert(&data, p, p)                            // normal = position on unit sphere
                }
            }
        }
        return buildMesh(device: device, data, vertexCount: rings * segs * 6)
    }

    private static func makePanel(device: MTLDevice) -> GPUMesh {
        // Unit quad in the XY plane facing +Z, with proper texture UVs
        // (v=0 at texture top row, matching CoreGraphics byte order).
        var data: [Float] = []
        let tl = SIMD3<Float>(-0.5, 0.5, 0), tr = SIMD3<Float>(0.5, 0.5, 0)
        let bl = SIMD3<Float>(-0.5, -0.5, 0), br = SIMD3<Float>(0.5, -0.5, 0)
        let n = SIMD3<Float>(0, 0, 1)
        appendVert(&data, tl, n, SIMD2<Float>(0, 0))
        appendVert(&data, bl, n, SIMD2<Float>(0, 1))
        appendVert(&data, br, n, SIMD2<Float>(1, 1))
        appendVert(&data, tl, n, SIMD2<Float>(0, 0))
        appendVert(&data, br, n, SIMD2<Float>(1, 1))
        appendVert(&data, tr, n, SIMD2<Float>(1, 0))
        return buildMesh(device: device, data, vertexCount: 6)
    }
}
