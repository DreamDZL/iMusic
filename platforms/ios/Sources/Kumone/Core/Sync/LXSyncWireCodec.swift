import Compression
import Foundation

enum LXSyncWireCodecError: LocalizedError {
    case malformedCompressedFrame
    case invalidUTF8
    case compressionFailed
    case messageTooLarge

    var errorDescription: String? {
        switch self {
        case .malformedCompressedFrame: return "LX Sync 压缩数据无效"
        case .invalidUTF8: return "LX Sync 消息不是有效的 UTF-8 文本"
        case .compressionFailed: return "LX Sync 消息压缩失败"
        case .messageTooLarge: return "LX Sync 消息超过安全大小限制"
        }
    }
}

/// LX Sync v4 frames are plain JSON up to 1,024 JavaScript UTF-16 code units.
/// Larger frames use `cg_` followed by a base64-encoded gzip member.
enum LXSyncWireCodec {
    static let compressionThreshold = 1_024
    private static let maximumMessageBytes = 32 * 1_024 * 1_024
    private static let maximumFrameBytes = maximumMessageBytes + maximumMessageBytes / 2
    private static let gzipHeader: [UInt8] = [0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0, 0x03]

    private static let crc32Table: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 {
            crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xedb8_8320 : crc >> 1
        }
        return crc
    }

    static func shouldCompress(_ message: String) -> Bool {
        message.utf16.count > compressionThreshold
    }

    static func shouldOffloadEncoding(_ message: String) -> Bool {
        message.utf8.count > compressionThreshold
    }

    static func shouldOffloadDecoding(_ frame: String) -> Bool {
        frame.hasPrefix("cg_") || frame.utf8.count > compressionThreshold
    }

    static func isHeartbeatFrame(_ frame: String) -> Bool {
        frame == "ping"
    }

    static func encode(_ message: String) throws -> String {
        guard message.utf8.count <= maximumMessageBytes else {
            throw LXSyncWireCodecError.messageTooLarge
        }
        guard shouldCompress(message) else { return message }

        let payload = Data(message.utf8)
        guard let deflated = deflateRaw(payload) else {
            throw LXSyncWireCodecError.compressionFailed
        }

        var gzip = Data(gzipHeader)
        gzip.append(deflated)
        appendLittleEndian(crc32(payload), to: &gzip)
        appendLittleEndian(UInt32(truncatingIfNeeded: payload.count), to: &gzip)
        let frame = "cg_" + gzip.base64EncodedString()
        guard frame.utf8.count <= maximumFrameBytes else {
            throw LXSyncWireCodecError.messageTooLarge
        }
        return frame
    }

    static func decode(_ frame: String) throws -> String {
        guard frame.utf8.count <= maximumFrameBytes else {
            throw LXSyncWireCodecError.messageTooLarge
        }
        guard frame.hasPrefix("cg_") else {
            guard frame.utf8.count <= maximumMessageBytes else {
                throw LXSyncWireCodecError.messageTooLarge
            }
            return frame
        }

        guard let gzip = Data(base64Encoded: String(frame.dropFirst(3))) else {
            throw LXSyncWireCodecError.malformedCompressedFrame
        }
        let decoded = try gunzip(gzip)
        guard let message = String(data: decoded, encoding: .utf8) else {
            throw LXSyncWireCodecError.invalidUTF8
        }
        return message
    }

    private static func deflateRaw(_ input: Data) -> Data? {
        guard !input.isEmpty else { return Data() }
        // DEFLATE's stored-block overhead is at most five bytes per 16 KiB,
        // plus a small stream header. Compression.framework emits raw DEFLATE
        // for COMPRESSION_ZLIB, which is the payload format inside gzip.
        let capacity = input.count + ((input.count / 16_383 + 1) * 5) + 6
        let output = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { output.deallocate() }

        let written = input.withUnsafeBytes { source in
            compression_encode_buffer(
                output,
                capacity,
                source.bindMemory(to: UInt8.self).baseAddress!,
                input.count,
                nil,
                COMPRESSION_ZLIB
            )
        }
        guard written > 0 else { return nil }
        return Data(bytes: output, count: written)
    }

    private static func gunzip(_ gzip: Data) throws -> Data {
        guard gzip.count >= 18,
              gzip[0] == 0x1f, gzip[1] == 0x8b, gzip[2] == 0x08,
              gzip[3] & 0xe0 == 0 else {
            throw LXSyncWireCodecError.malformedCompressedFrame
        }

        let flags = gzip[3]
        let trailerStart = gzip.count - 8
        var payloadStart = 10

        if flags & 0x04 != 0 {
            guard payloadStart + 2 <= trailerStart else {
                throw LXSyncWireCodecError.malformedCompressedFrame
            }
            let extraLength = Int(gzip[payloadStart]) | (Int(gzip[payloadStart + 1]) << 8)
            payloadStart += 2 + extraLength
            guard payloadStart <= trailerStart else {
                throw LXSyncWireCodecError.malformedCompressedFrame
            }
        }
        if flags & 0x08 != 0 {
            guard let next = zeroTerminatedFieldEnd(in: gzip, startingAt: payloadStart, before: trailerStart) else {
                throw LXSyncWireCodecError.malformedCompressedFrame
            }
            payloadStart = next
        }
        if flags & 0x10 != 0 {
            guard let next = zeroTerminatedFieldEnd(in: gzip, startingAt: payloadStart, before: trailerStart) else {
                throw LXSyncWireCodecError.malformedCompressedFrame
            }
            payloadStart = next
        }
        if flags & 0x02 != 0 {
            guard payloadStart + 2 <= trailerStart else {
                throw LXSyncWireCodecError.malformedCompressedFrame
            }
            let expectedHeaderCRC = UInt16(gzip[payloadStart]) | (UInt16(gzip[payloadStart + 1]) << 8)
            let actualHeaderCRC = UInt16(truncatingIfNeeded: crc32(gzip, range: 0..<payloadStart))
            guard expectedHeaderCRC == actualHeaderCRC else {
                throw LXSyncWireCodecError.malformedCompressedFrame
            }
            payloadStart += 2
        }
        guard payloadStart <= trailerStart else {
            throw LXSyncWireCodecError.malformedCompressedFrame
        }

        let expectedCRC = readLittleEndianUInt32(gzip, at: trailerStart)
        let expectedSize = readLittleEndianUInt32(gzip, at: trailerStart + 4)
        guard let payload = inflateRaw(gzip, range: payloadStart..<trailerStart),
              UInt32(truncatingIfNeeded: payload.count) == expectedSize,
              crc32(payload) == expectedCRC else {
            throw LXSyncWireCodecError.malformedCompressedFrame
        }
        return payload
    }

    private static func inflateRaw(_ input: Data, range: Range<Int>) -> Data? {
        guard !range.isEmpty, range.lowerBound >= 0, range.upperBound <= input.count else { return nil }
        let maximumCapacity = maximumMessageBytes + 1
        var capacity = min(max(range.count * 8, 64 * 1_024), maximumCapacity)

        while true {
            let output = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            defer { output.deallocate() }
            let written = input.withUnsafeBytes { source in
                compression_decode_buffer(
                    output,
                    capacity,
                    source.bindMemory(to: UInt8.self).baseAddress!.advanced(by: range.lowerBound),
                    range.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
            guard written > 0 else { return nil }
            if written < capacity {
                guard written <= maximumMessageBytes else { return nil }
                return Data(bytes: output, count: written)
            }
            guard capacity < maximumCapacity else { return nil }
            capacity = min(capacity * 2, maximumCapacity)
        }
    }

    private static func crc32(_ data: Data, range: Range<Int>? = nil) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for offset in (range ?? (0..<data.count)) {
            let index = Int((crc ^ UInt32(data[offset])) & 0xff)
            crc = (crc >> 8) ^ crc32Table[index]
        }
        return ~crc
    }

    private static func zeroTerminatedFieldEnd(in data: Data, startingAt: Int, before end: Int) -> Int? {
        guard startingAt < end else { return nil }
        for offset in startingAt..<end where data[offset] == 0 {
            return offset + 1
        }
        return nil
    }

    private static func appendLittleEndian(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    private static func readLittleEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}
