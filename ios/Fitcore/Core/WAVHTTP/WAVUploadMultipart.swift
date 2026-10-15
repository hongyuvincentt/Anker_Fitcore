import Foundation
import CryptoKit

/// Client-side mirror of the server upload constraints:
/// 16 kHz / mono / 16-bit PCM WAV, non-empty, non-silent, at most 7,000,000 bytes.
/// This local screen never replaces backend validation; it only fails fast so a
/// retry keeps its identity instead of sending bytes the contract forbids.
enum WAVUploadValidator {
    static let maximumFileBytes = 7_000_000
    /// Silence threshold identical to the capture path local screen (-60 dBFS).
    static let minimumRMS = 0.001

    struct Inspection: Sendable, Equatable {
        let sha256: String
        let sizeBytes: Int
        let durationSeconds: Double
        let rmsDBFS: Double
        let peakDBFS: Double
    }

    static func validate(_ data: Data) throws -> Inspection {
        guard data.count <= maximumFileBytes else {
            throw BackendHTTPError.invalidUpload("WAV 文件超过 7,000,000 字节")
        }
        guard data.count >= 44 else {
            throw BackendHTTPError.invalidUpload("WAV 数据不足最小文件头长度")
        }
        let bytes = [UInt8](data)
        guard fourCC(bytes, 0) == "RIFF", fourCC(bytes, 8) == "WAVE" else {
            throw BackendHTTPError.invalidUpload("需要真实 RIFF/WAVE 文件")
        }
        var formatRange: Range<Int>?
        var audioRange: Range<Int>?
        var offset = 12
        while offset + 8 <= bytes.count {
            let id = fourCC(bytes, offset)
            let chunkSize = uint32(bytes, offset + 4)
            let start = offset + 8
            guard chunkSize <= bytes.count - start else {
                throw BackendHTTPError.invalidUpload("WAV chunk 内容不完整")
            }
            let end = start + chunkSize
            if id == "fmt " {
                guard formatRange == nil, chunkSize >= 16 else {
                    throw BackendHTTPError.invalidUpload("fmt chunk 非法")
                }
                formatRange = start..<(start + 16)
            } else if id == "data" {
                guard audioRange == nil else {
                    throw BackendHTTPError.invalidUpload("重复 data chunk")
                }
                audioRange = start..<end
            }
            offset = end + (chunkSize % 2)
        }
        guard let format = formatRange else { throw BackendHTTPError.invalidUpload("缺少 fmt chunk") }
        guard let audio = audioRange else { throw BackendHTTPError.invalidUpload("缺少 data chunk") }
        guard uint16(bytes, format.lowerBound) == 1 else { throw BackendHTTPError.invalidUpload("仅支持 PCM（formatTag 1）") }
        guard uint16(bytes, format.lowerBound + 2) == 1 else { throw BackendHTTPError.invalidUpload("必须为单声道") }
        guard uint32(bytes, format.lowerBound + 4) == 16_000 else { throw BackendHTTPError.invalidUpload("采样率必须为 16000 Hz") }
        guard uint16(bytes, format.lowerBound + 14) == 16 else { throw BackendHTTPError.invalidUpload("位深必须为 16 bit") }
        guard !audio.isEmpty, audio.count.isMultiple(of: 2) else { throw BackendHTTPError.invalidUpload("音频数据为空或含不完整帧") }

        let frameCount = audio.count / 2
        var sumSquares = 0.0
        var peak = 0.0
        var index = audio.lowerBound
        while index < audio.upperBound {
            let raw = UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
            let sample = Double(Int16(bitPattern: raw)) / 32_768.0
            sumSquares += sample * sample
            peak = max(peak, abs(sample))
            index += 2
        }
        let rms = (sumSquares / Double(frameCount)).squareRoot()
        guard rms >= minimumRMS else {
            throw BackendHTTPError.invalidUpload("本地静音筛查未通过（RMS ≤ -60 dBFS），不会发送该音频")
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return Inspection(
            sha256: digest,
            sizeBytes: data.count,
            durationSeconds: Double(frameCount) / 16_000.0,
            rmsDBFS: 20 * log10(rms),
            peakDBFS: 20 * log10(peak)
        )
    }

    private static func fourCC(_ bytes: [UInt8], _ offset: Int) -> String {
        String(decoding: bytes[offset..<(offset + 4)], as: UTF8.self)
    }

    private static func uint16(_ bytes: [UInt8], _ offset: Int) -> Int {
        Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
    }

    private static func uint32(_ bytes: [UInt8], _ offset: Int) -> Int {
        Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
            | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
    }
}

/// Multipart body for POST /v1/sessions/{sid}/audio-jobs. Only the contract
/// fields are emitted (file, utterance_id, sequence, optional audio_source) —
/// never unknown or duplicate fields, never a Data URI or external URL.
enum WAVMultipartEncoder {
    static let maximumTotalBytes = 7_065_536

    static func encode(
        boundary: String,
        file: Data,
        utteranceID: String,
        sequence: Int,
        audioSource: String?
    ) throws -> Data {
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(utteranceID).wav\"\r\n".utf8))
        body.append(Data("Content-Type: audio/wav\r\n\r\n".utf8))
        body.append(file)
        body.append(Data("\r\n".utf8))
        func appendField(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data(value.utf8))
            body.append(Data("\r\n".utf8))
        }
        appendField("utterance_id", utteranceID)
        appendField("sequence", String(sequence))
        if let audioSource {
            appendField("audio_source", audioSource)
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        guard body.count <= maximumTotalBytes else {
            throw BackendHTTPError.invalidUpload("multipart 总大小超过 7,065,536 字节")
        }
        return body
    }
}
