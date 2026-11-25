import CoreMedia
import Foundation

// HEVC/H.265 decode pipeline for the PC streaming path.
//
// SKELETON STATUS: parses Annex-B streams and extracts VPS/SPS/PPS parameter
// sets (needed to build the VideoToolbox format description), counts frames,
// and buffers access units. The VTDecompressionSession and Metal texture
// upload land together with in-VR video display on the stream panel — built
// against a real server stream rather than compiled blind.
final class HEVCDecoder {

    struct ParameterSets {
        var vps: Data
        var sps: Data
        var pps: Data
    }

    private(set) var parameterSets: ParameterSets?
    private(set) var lastFrameIndex: UInt32 = 0
    private(set) var receivedFrames = 0

    /// Feed one server chunk (Annex-B, with VPS/SPS/PPS in the first frame).
    func decode(_ data: Data, frameIndex: UInt32) {
        lastFrameIndex = frameIndex
        receivedFrames += 1
        if parameterSets == nil {
            parameterSets = extractParameterSets(from: data)
        }
    }

    /// Scans a Annex-B elementary stream for VPS (32), SPS (33), PPS (34) NALs.
    func extractParameterSets(from data: Data) -> ParameterSets? {
        let bytes = [UInt8](data)
        guard bytes.count > 4 else { return nil }

        var starts: [Int] = []
        var i = 0
        while i + 4 <= bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 0, bytes[i + 3] == 1 {
                starts.append(i + 4)
                i += 4
            } else {
                i += 1
            }
        }

        var vps: Data?
        var sps: Data?
        var pps: Data?
        for (idx, start) in starts.enumerated() {
            let end = idx + 1 < starts.count ? starts[idx + 1] - 4 : bytes.count
            guard start < bytes.count, end <= bytes.count, start < end else { continue }
            let nalType = (bytes[start] >> 1) & 0x3F
            let nal = Data(bytes[start..<end])
            switch nalType {
            case 32: vps = nal
            case 33: sps = nal
            case 34: pps = nal
            default: break
            }
        }
        guard let v = vps, let s = sps, let p = pps else { return nil }
        return ParameterSets(vps: v, sps: s, pps: p)
    }
}
