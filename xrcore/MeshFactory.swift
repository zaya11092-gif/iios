import MetalKit
import ModelIO

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

// Procedural geometry: unit box [-0.5, 0.5]^3 (CCW, non-indexed) and unit
// sphere (radius 1, ModelIO) — everything is scaled by the model matrix.
enum MeshFactory {

    static func makeMeshes(device: MTLDevice) -> [MeshKind: GPUMesh] {
        var meshes: [MeshKind: GPUMesh] = [:]
        meshes[.box] = makeBox(device: device)
        meshes[.sphere] = makeSphere(device: device)
        return meshes
    }

    private static func makeBox(device: MTLDevice) -> GPUMesh {
        // CCW winding viewed from outside (Metal pipelines use
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

        let vb = device.makeBuffer(bytes: data, length: data.count * MemoryLayout<Float>.size, options: .storageModeShared)!
        return GPUMesh(vertexBuffer: vb, indexBuffer: nil, vertexCount: 36, indexCount: 0, indexType: .uint32)
    }

    private static func makeSphere(device: MTLDevice) -> GPUMesh {
        let d = MDLVertexDescriptor()
        d.attributes = [
            MDLVertexAttribute(name: MDLVertexAttributePosition, format: .float3, offset: 0, bufferIndex: 0),
            MDLVertexAttribute(name: MDLVertexAttributeNormal, format: .float3, offset: 12, bufferIndex: 0),
        ]
        d.layouts[0] = MDLVertexBufferLayout(stride: 24)

        let mdl = MDLMesh(sphereWithRadius: 1.0, segments: 24, segments: 16,
                          inwardNormals: false, geometryType: .triangles, device: device)
        mdl.vertexDescriptor = d
        guard let mtk = try? MTKMesh(mesh: mdl, device: device),
              let sub = mtk.submeshes.first as? MTKSubmesh else {
            // Should never happen; fall back to the box.
            return makeBox(device: device)
        }
        return GPUMesh(vertexBuffer: mtk.vertexBuffers[0].buffer,
                       indexBuffer: sub.indexBuffer.buffer,
                       vertexCount: mtk.vertexCount,
                       indexCount: sub.indexCount,
                       indexType: sub.indexType)
    }
}
