import Foundation
import CryptoKit

struct WAVInspection: Codable, Equatable, Sendable {
    let sampleRate: Int
    let channels: Int
    let bitsPerSample: Int
    let frameCount: Int
    let durationSeconds: Double
    let sizeBytes: Int
    let sha256: String
    let rmsDBFS: Double
    let peakDBFS: Double

    enum CodingKeys: String, CodingKey {
        case sampleRate = "sample_rate"
        case channels
        case bitsPerSample = "bits_per_sample"
        case frameCount = "frame_count"
        case durationSeconds = "duration_seconds"
        case sizeBytes = "size_bytes"
        case sha256
        case rmsDBFS = "rms_dbfs"
        case peakDBFS = "peak_dbfs"
    }
}

enum WAVFileValidator {
    private static let maximumSize = 7_000_000

    static func inspect(url: URL) throws -> WAVInspection {
        guard url.isFileURL else { throw ValidationError.unreadable }
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw ValidationError.unreadable
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber else {
            throw ValidationError.unreadable
        }
        // Reject large files from metadata before loading any audio bytes.
        guard size.uint64Value <= UInt64(maximumSize) else { throw ValidationError.tooLarge }

        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var bytes = Data()
            // Bound reads even if the file grows after the size check.
            while bytes.count <= maximumSize {
                let next = try handle.read(upToCount: min(65_536, maximumSize + 1 - bytes.count)) ?? Data()
                if next.isEmpty { break }
                bytes.append(next)
            }
            data = bytes
        } catch {
            throw ValidationError.unreadable
        }
        return try inspect(data: data)
    }

    static func inspect(data: Data) throws -> WAVInspection {
        guard data.count <= maximumSize else { throw ValidationError.tooLarge }
        guard data.count >= 12 else { throw ValidationError.invalid("缺少 RIFF/WAVE 文件头") }
        let bytes = [UInt8](data)
        guard fourCC(bytes, at: 0) == "RIFF", fourCC(bytes, at: 8) == "WAVE" else {
            throw ValidationError.invalid("需要真实 RIFF/WAVE 文件")
        }
        let declaredSize = uint32(bytes, at: 4) + 8
        guard declaredSize <= bytes.count else { throw ValidationError.truncated("RIFF 长度超过实际文件") }
        guard declaredSize == bytes.count else { throw ValidationError.invalid("RIFF 长度与实际文件不一致") }

        var formatOffset: Int?
        var audioRange: Range<Int>?
        var offset = 12
        while offset < bytes.count {
            guard bytes.count - offset >= 8 else { throw ValidationError.truncated("chunk 文件头不完整") }
            let id = fourCC(bytes, at: offset)
            let chunkSize = uint32(bytes, at: offset + 4)
            let start = offset + 8
            guard chunkSize <= bytes.count - start else { throw ValidationError.truncated("\(id) chunk 内容不完整") }
            let end = start + chunkSize
            let paddedEnd = end + (chunkSize % 2)
            guard paddedEnd <= bytes.count else { throw ValidationError.truncated("\(id) chunk 缺少奇数长度填充") }
            if id == "fmt " {
                guard formatOffset == nil else { throw ValidationError.invalid("重复 fmt chunk") }
                guard chunkSize >= 16 else { throw ValidationError.format("fmt chunk 至少需要 16 字节") }
                formatOffset = start
            } else if id == "data" {
                guard audioRange == nil else { throw ValidationError.invalid("重复 data chunk") }
                audioRange = start..<end
            }
            offset = paddedEnd
        }

        guard let formatOffset else { throw ValidationError.invalid("缺少 fmt chunk") }
        guard let audioRange else { throw ValidationError.invalid("缺少 data chunk") }
        guard uint16(bytes, at: formatOffset) == 1 else { throw ValidationError.format("仅支持经典 PCM（formatTag 1）") }
        let channels = uint16(bytes, at: formatOffset + 2)
        let sampleRate = uint32(bytes, at: formatOffset + 4)
        let byteRate = uint32(bytes, at: formatOffset + 8)
        let blockAlign = uint16(bytes, at: formatOffset + 12)
        let bitsPerSample = uint16(bytes, at: formatOffset + 14)
        guard sampleRate == 16_000 else { throw ValidationError.format("采样率必须为 16000 Hz") }
        guard channels == 1 else { throw ValidationError.format("必须为单声道") }
        guard bitsPerSample == 16 else { throw ValidationError.format("位深必须为 16 bit") }
        guard blockAlign == 2 else { throw ValidationError.format("blockAlign 必须为 2") }
        guard byteRate == sampleRate * blockAlign else { throw ValidationError.format("byteRate 与采样率、blockAlign 不一致") }
        guard !audioRange.isEmpty else { throw ValidationError.empty }
        guard audioRange.count.isMultiple(of: blockAlign) else { throw ValidationError.format("data 包含不完整的 PCM 帧") }

        let frameCount = audioRange.count / blockAlign
        var sumSquares = 0.0
        var peak = 0.0
        for index in stride(from: audioRange.lowerBound, to: audioRange.upperBound, by: 2) {
            let raw = UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
            let sample = Double(Int16(bitPattern: raw)) / 32_768.0
            sumSquares += sample * sample
            peak = max(peak, abs(sample))
        }
        let rms = sqrt(sumSquares / Double(frameCount))
        // Local silence screening only; this does not replace backend validation.
        guard rms > 0.001 else { throw ValidationError.silent }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return WAVInspection(
            sampleRate: sampleRate,
            channels: channels,
            bitsPerSample: bitsPerSample,
            frameCount: frameCount,
            durationSeconds: Double(frameCount) / Double(sampleRate),
            sizeBytes: data.count,
            sha256: digest,
            rmsDBFS: 20 * log10(rms),
            peakDBFS: 20 * log10(peak)
        )
    }

    private static func fourCC(_ bytes: [UInt8], at offset: Int) -> String {
        String(decoding: bytes[offset..<(offset + 4)], as: UTF8.self)
    }

    private static func uint16(_ bytes: [UInt8], at offset: Int) -> Int {
        Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
    }

    private static func uint32(_ bytes: [UInt8], at offset: Int) -> Int {
        Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
    }

    private enum ValidationError: LocalizedError {
        case unreadable
        case tooLarge
        case invalid(String)
        case truncated(String)
        case format(String)
        case empty
        case silent

        var errorDescription: String? {
            switch self {
            case .unreadable: return "无法读取 WAV 文件，请确认文件存在且可访问。"
            case .tooLarge: return "WAV 文件过大，不得超过 7,000,000 字节。"
            case .invalid(let reason): return "无效 WAV：\(reason)。"
            case .truncated(let reason): return "WAV 文件已截断：\(reason)。"
            case .format(let reason): return "WAV 格式不支持：\(reason)。"
            case .empty: return "WAV 的 data 音频内容为空。"
            case .silent: return "本地静音筛查未通过（RMS ≤ -60 dBFS），请重新录制；本地筛查不替代后端验证。"
            }
        }
    }
}
