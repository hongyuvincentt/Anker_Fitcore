import Foundation
import XCTest
@testable import WAVCaptureKit

final class WAVFileValidatorTests: XCTestCase {
    func testInspectsRealPCMAndFiniteDecodableMetadata() throws {
        let data = wav(samples: [16_384, -16_384, 16_384, -16_384])
        let result = try WAVFileValidator.inspect(data: data)
        XCTAssertEqual(result.sampleRate, 16_000)
        XCTAssertEqual(result.channels, 1)
        XCTAssertEqual(result.bitsPerSample, 16)
        XCTAssertEqual(result.frameCount, 4)
        XCTAssertEqual(result.durationSeconds, 0.00025)
        XCTAssertEqual(result.sizeBytes, 52)
        XCTAssertEqual(result.rmsDBFS, -6.020599913279624, accuracy: 0.0000001)
        XCTAssertEqual(result.peakDBFS, -6.020599913279624, accuracy: 0.0000001)
        let encoded = try JSONEncoder().encode(result)
        XCTAssertEqual(try JSONDecoder().decode(WAVInspection.self, from: encoded), result)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(json.keys), Set(["sample_rate", "channels", "bits_per_sample", "frame_count", "duration_seconds", "size_bytes", "sha256", "rms_dbfs", "peak_dbfs"]))
    }

    func testHashesEntireFileWithKnownSHA256() throws {
        // Independent digest produced with Python hashlib for this exact 52-byte PCM fixture.
        let result = try WAVFileValidator.inspect(data: wav(samples: [16_384, -16_384, 16_384, -16_384]))
        XCTAssertEqual(result.sha256, "82ea02283f3f8bbb5e77ed918757e696bf97c62bd154cdae295c28182c3eaafa")
    }

    func testAcceptsExtraChunksAndRequiredOddPadding() throws {
        let extra = chunk("JUNK", Data([1, 2, 3]))
        let trailing = chunk("LIST", Data([4, 5]))
        let data = waveBody(extra + chunk("fmt ", format()) + chunk("data", pcm([32_767, -32_768])) + trailing)
        let result = try WAVFileValidator.inspect(data: data)
        XCTAssertEqual(result.frameCount, 2)
        XCTAssertEqual(result.peakDBFS, 0)
        XCTAssertEqual(result.sizeBytes, 70)
    }

    func testAcceptsDataBeforeFormat() throws {
        let data = waveBody(chunk("data", pcm([4096])) + chunk("fmt ", format()))
        XCTAssertEqual(try WAVFileValidator.inspect(data: data).frameCount, 1)
    }

    func testRejectsNonWAVAndShortHeaders() {
        assertRejected(Data(), reason: "无效")
        assertRejected(Data("not a WAV file".utf8), reason: "无效")
        var data = wav()
        data.replaceSubrange(8..<12, with: Data("AIFF".utf8))
        assertRejected(data, reason: "无效")
    }

    func testRejectsTruncatedRIFFAndUnexpectedTrailingBytes() {
        var truncated = wav()
        truncated.removeLast()
        assertRejected(truncated, reason: "截断")
        var trailing = wav()
        trailing.append(0)
        assertRejected(trailing, reason: "长度")
    }

    func testRejectsTruncatedChunkHeaderAndPayload() {
        assertRejected(waveBody(chunk("fmt ", format()) + Data("JUNK".utf8)), reason: "截断")
        var badChunk = Data("data".utf8)
        badChunk.append(le32(100))
        badChunk.append(contentsOf: [0, 1])
        assertRejected(waveBody(chunk("fmt ", format()) + badChunk), reason: "截断")
    }

    func testRejectsMissingOddPadding() {
        var body = chunk("fmt ", format())
        body.append(Data("JUNK".utf8))
        body.append(le32(1))
        body.append(1)
        assertRejected(waveBody(body), reason: "截断")
    }

    func testRejectsMissingOrDuplicateRequiredChunks() {
        assertRejected(waveBody(chunk("fmt ", format())), reason: "data")
        assertRejected(waveBody(chunk("data", pcm([4096]))), reason: "fmt")
        assertRejected(waveBody(chunk("fmt ", format()) + chunk("fmt ", format()) + chunk("data", pcm([4096]))), reason: "重复")
        assertRejected(waveBody(chunk("fmt ", format()) + chunk("data", pcm([4096])) + chunk("data", pcm([4096]))), reason: "重复")
    }

    func testRejectsShortFormatChunk() {
        assertRejected(waveBody(chunk("fmt ", Data([1, 0])) + chunk("data", pcm([4096]))), reason: "格式")
    }

    func testRejectsWrongRateChannelsDepthFloatAndExtensibleFormats() {
        assertRejected(wav(fmt: format(rate: 44_100)), reason: "16000")
        assertRejected(wav(fmt: format(channels: 2)), reason: "单声道")
        assertRejected(wav(fmt: format(bits: 8)), reason: "16")
        assertRejected(wav(fmt: format(tag: 3)), reason: "PCM")
        assertRejected(wav(fmt: format(tag: 0xFFFE)), reason: "PCM")
    }

    func testRejectsInconsistentBlockAlignAndByteRate() {
        assertRejected(wav(fmt: format(align: 4)), reason: "blockAlign")
        assertRejected(wav(fmt: format(byteRate: 16_000)), reason: "byteRate")
    }

    func testRejectsEmptyAndIncompletePCMFrames() {
        assertRejected(wav(samples: []), reason: "空")
        assertRejected(waveBody(chunk("fmt ", format()) + chunk("data", Data([100]))), reason: "帧")
    }

    func testRejectsZeroAndBelowThresholdSilenceButAcceptsAudiblePCM() throws {
        assertRejected(wav(samples: [0, 0, 0]), reason: "静音")
        assertRejected(wav(samples: [32, -32]), reason: "静音")
        let result = try WAVFileValidator.inspect(data: wav(samples: [33, -33]))
        XCTAssertGreaterThan(result.rmsDBFS, -60)
        XCTAssertTrue(result.rmsDBFS.isFinite)
        XCTAssertTrue(result.peakDBFS.isFinite)
    }

    func testRejectsOversizeDataBeforeParsing() {
        assertRejected(Data(repeating: 0, count: 7_000_001), reason: "7,000,000")
    }

    func testAcceptsExactFileSizeLimit() throws {
        let data = wav(samples: Array(repeating: 4096, count: 3_499_978))
        XCTAssertEqual(data.count, 7_000_000)
        XCTAssertEqual(try WAVFileValidator.inspect(data: data).frameCount, 3_499_978)
    }

    func testURLInspectionMatchesData() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let data = wav()
        try data.write(to: url)
        XCTAssertEqual(try WAVFileValidator.inspect(url: url), try WAVFileValidator.inspect(data: data))
    }

    func testRejectsOversizeSparseFileBeforeReadingOrParsing() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 8_000_000_000)
        try handle.close()
        XCTAssertThrowsError(try WAVFileValidator.inspect(url: url)) { error in
            XCTAssertTrue(error.localizedDescription.contains("7,000,000"), error.localizedDescription)
        }
    }

    func testRejectsUnreadableMissingFileAndDirectory() {
        for url in [temporaryURL(), FileManager.default.temporaryDirectory] {
            XCTAssertThrowsError(try WAVFileValidator.inspect(url: url)) { error in
                XCTAssertTrue(error.localizedDescription.contains("读取"), error.localizedDescription)
            }
        }
    }

    private func assertRejected(_ data: Data, reason: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try WAVFileValidator.inspect(data: data), file: file, line: line) { error in
            XCTAssertTrue(error.localizedDescription.contains(reason), error.localizedDescription, file: file, line: line)
        }
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("wav-validator-\(UUID().uuidString).wav")
    }

    private func wav(samples: [Int16] = [4096, -4096], fmt: Data? = nil) -> Data {
        waveBody(chunk("fmt ", fmt ?? format()) + chunk("data", pcm(samples)))
    }

    private func waveBody(_ chunks: Data) -> Data {
        Data("RIFF".utf8) + le32(UInt32(chunks.count + 4)) + Data("WAVE".utf8) + chunks
    }

    private func chunk(_ id: String, _ payload: Data) -> Data {
        Data(id.utf8) + le32(UInt32(payload.count)) + payload + (payload.count.isMultiple(of: 2) ? Data() : Data([0]))
    }

    private func format(tag: UInt16 = 1, channels: UInt16 = 1, rate: UInt32 = 16_000, bits: UInt16 = 16, align: UInt16 = 2, byteRate: UInt32 = 32_000) -> Data {
        le16(tag) + le16(channels) + le32(rate) + le32(byteRate) + le16(align) + le16(bits)
    }

    private func pcm(_ samples: [Int16]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples { data.append(le16(UInt16(bitPattern: sample))) }
        return data
    }

    private func le16(_ value: UInt16) -> Data {
        Data([UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)])
    }

    private func le32(_ value: UInt32) -> Data {
        Data([UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 24)])
    }
}
