import Metal

enum MeshKind: Int {
    case box = 0
    case sphere = 1
}

struct GPUMesh {
    let vertexBuffer: MTLBuffer
    let indexBuffer: MTLBuffer?   // nil -> non-indexed, draw vertexCount verts
    let vertexCount: Int
    let indexCount: Int
    let indexType: MTLIndexType
}

// Procedural geometry: unit box [-0.5, 0.5]^3 and unit sphere (radius 1),
// both CCW, non-indexed, interleaved pos(3)+normal(3) — everything is scaled
// by the model matrix. Written by hand (no ModelIO) to keep the vertex layout
// identical for both meshes.
enum MeshFactory {

    static func makeMeshes(device: MTLDevice) -> [MeshKind: GPUMesh] {
        var meshes: [MeshKind: GPUMesh] = [:]
        meshes[.box] = makeBox(device: device)
        meshes[.sphere] = makeSphere(device: device)
        return meshes
    }

    private static func buildMesh(device: MTLDevice, _ data: [Float], vertexCount: Int) -> GPUMesh {
        let vb = device.makeBuffer(bytes: data, length: data.count * MemoryLayout<Float>.size, options: .storageModeShared)!
        return GPUMesh(vertexBuffer: vb, indexBuffer: nil, vertexCount: vertexCount, indexCount: 0, indexType: .uint32)
    }

    private static func makeBox(device: MTLDevice) -> GPUMesh {
        // CCW winding viewed from outside (pipelines use
        // frontFacing(.counterClockwise), cullMode(.back)).
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
        data.reserveCapacity(36 * 6)
        for (i, face) in f.enumerated() {
            let n = normals[i]
            var v = 0
            while v < face.count {
                data.append(contentsOf: [face[v], face[v + 1], face[v + 2]])
                data.append(contentsOf: n)
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
        data.reserveCapacity(rings * segs * 6 * 6)
        for i in 0..<rings {
            for j in 0..<segs {
                let p00 = point(i, j)
                let p01 = point(i, j + 1)
                let p10 = point(i + 1, j)
                let p11 = point(i + 1, j + 1)
                // CCW triangles facing outward: (p00,p11,p10) and (p00,p01,p11)
                for p in [p00, p11, p10, p00, p01, p11] {
                    data.append(contentsOf: [p.x, p.y, p.z, p.x, p.y, p.z]) // pos + normal
                }
            }
        }
        return buildMesh(device: device, data, vertexCount: rings * segs * 6)
    }
}
