import Foundation

/// Wire-level frame structure for cross-platform IPC transport.
///
/// Frame format (18-byte header + variable-length payload):
/// | Offset | Field           | Type    | Bytes | Details |
/// | 0–3    | magic           | u32 BE  | 4     | 0x46534E58 (FSNX) |
/// | 4      | version         | u8      | 1     | 1 |
/// | 5      | flags           | u8      | 1     | bit 0: is_reply |
/// | 6–13   | correlation_id  | u64 LE  | 8     | 0 for notify |
/// | 14–17  | payload_len     | u32 LE  | 4     | max 16 MB (R3.8) |
/// | 18+    | payload         | bytes   | N     | FreeSnitchWireCodec JSON |
///
/// Header is 18 bytes. Frames exceeding the 16 MB payload cap are rejected
/// before the payload is read, preventing unbounded buffering (R3.8).
public struct HelperFrame: Sendable {
    public let method: String  // Not in wire format; convenience for protocol layer
    public let payload: Data
    public let expectsReply: Bool
    public let correlationID: UInt64

    public init(method: String, payload: Data, expectsReply: Bool, correlationID: UInt64) {
        self.method = method
        self.payload = payload
        self.expectsReply = expectsReply
        self.correlationID = correlationID
    }

    /// Encodes this frame to wire format.
    public func encode() -> Data {
        var buffer = Data(capacity: 18 + payload.count)

        // Magic: 0x46534E58 (FSNX, big-endian)
        let magic: UInt32 = 0x46534E58
        buffer.append(UInt8((magic >> 24) & 0xFF))
        buffer.append(UInt8((magic >> 16) & 0xFF))
        buffer.append(UInt8((magic >> 8) & 0xFF))
        buffer.append(UInt8(magic & 0xFF))

        // Version: 1
        buffer.append(UInt8(1))

        // Flags: bit 0 = expectsReply
        let flags = expectsReply ? UInt8(1) : UInt8(0)
        buffer.append(flags)

        // Correlation ID: little-endian u64
        let corrID = correlationID
        buffer.append(UInt8(corrID & 0xFF))
        buffer.append(UInt8((corrID >> 8) & 0xFF))
        buffer.append(UInt8((corrID >> 16) & 0xFF))
        buffer.append(UInt8((corrID >> 24) & 0xFF))
        buffer.append(UInt8((corrID >> 32) & 0xFF))
        buffer.append(UInt8((corrID >> 40) & 0xFF))
        buffer.append(UInt8((corrID >> 48) & 0xFF))
        buffer.append(UInt8((corrID >> 56) & 0xFF))

        // Payload length: little-endian u32
        let len = UInt32(payload.count)
        buffer.append(UInt8(len & 0xFF))
        buffer.append(UInt8((len >> 8) & 0xFF))
        buffer.append(UInt8((len >> 16) & 0xFF))
        buffer.append(UInt8((len >> 24) & 0xFF))

        // Payload
        buffer.append(payload)

        return buffer
    }

    /// Decodes a frame from wire format.
    /// Returns the decoded frame and any remaining bytes after it.
    /// Throws if the data is malformed or the payload exceeds the cap.
    public static func decode(_ data: Data) throws -> (HelperFrame, remaining: Data) {
        guard data.count >= 18 else {
            throw HelperFrameError.incomplete
        }

        // Magic
        let magic = UInt32(data[0]) << 24 | UInt32(data[1]) << 16 | UInt32(data[2]) << 8 | UInt32(data[3])
        guard magic == 0x46534E58 else {
            throw HelperFrameError.invalidMagic
        }

        // Version
        let version = data[4]
        guard version == 1 else {
            throw HelperFrameError.unknownVersion
        }

        // Flags
        let flags = data[5]
        let expectsReply = (flags & 1) != 0

        // Correlation ID (little-endian)
        var corrID = UInt64(data[6])
        corrID |= UInt64(data[7]) << 8
        corrID |= UInt64(data[8]) << 16
        corrID |= UInt64(data[9]) << 24
        corrID |= UInt64(data[10]) << 32
        corrID |= UInt64(data[11]) << 40
        corrID |= UInt64(data[12]) << 48
        corrID |= UInt64(data[13]) << 56

        // Payload length (little-endian)
        var payloadLen = UInt32(data[14])
        payloadLen |= UInt32(data[15]) << 8
        payloadLen |= UInt32(data[16]) << 16
        payloadLen |= UInt32(data[17]) << 24

        // Check payload size BEFORE attempting to read it (R3.8)
        let maxPayloadBytes: UInt32 = 16 * 1024 * 1024
        guard payloadLen <= maxPayloadBytes else {
            throw HelperFrameError.oversizedPayload
        }

        // Check if we have the full payload
        let totalNeeded = 18 + Int(payloadLen)
        guard data.count >= totalNeeded else {
            throw HelperFrameError.incomplete
        }

        // Extract payload
        let payload = Data(data[18..<(18 + Int(payloadLen))])

        // Remaining bytes
        let remaining = data.count > totalNeeded ? Data(data[totalNeeded...]) : Data()

        let frame = HelperFrame(method: "", payload: payload, expectsReply: expectsReply, correlationID: corrID)
        return (frame, remaining)
    }
}

/// Errors produced by frame encoding/decoding.
public enum HelperFrameError: LocalizedError, Equatable, Sendable {
    case incomplete
    case invalidMagic
    case unknownVersion
    case oversizedPayload

    public var errorDescription: String? {
        switch self {
        case .incomplete:
            return "Frame is incomplete; more bytes needed."
        case .invalidMagic:
            return "Invalid frame magic."
        case .unknownVersion:
            return "Unknown frame version."
        case .oversizedPayload:
            return "Payload exceeds 16 MB limit (R3.8)."
        }
    }
}

/// Stateful decoder for assembling frames from a byte stream.
///
/// Handles partial reads: feed bytes as they arrive, and the decoder returns
/// a complete frame when all 18 bytes of header plus the declared payload
/// have been received. Does not desynchronize on partial reads.
public final class HelperFrameDecoder: Sendable {
    private var buffer = Data()

    public init() {}

    /// Feeds a chunk of bytes to the decoder.
    /// Returns a complete frame if one is ready, or nil if more bytes are needed.
    /// Throws on malformed input.
    ///
    /// The decoder buffers input internally and does not require callers to
    /// fragment or align reads. Partial frames are held until complete.
    public func feed(_ chunk: Data) throws -> HelperFrame? {
        buffer.append(chunk)

        // Need at least header to check magic/version/length
        if buffer.count < 18 {
            return nil
        }

        // Magic
        let magic = UInt32(buffer[0]) << 24 | UInt32(buffer[1]) << 16 | UInt32(buffer[2]) << 8 | UInt32(buffer[3])
        guard magic == 0x46534E58 else {
            throw HelperFrameError.invalidMagic
        }

        // Version
        let version = buffer[4]
        guard version == 1 else {
            throw HelperFrameError.unknownVersion
        }

        // Payload length (little-endian) at offset 14
        var payloadLen = UInt32(buffer[14])
        payloadLen |= UInt32(buffer[15]) << 8
        payloadLen |= UInt32(buffer[16]) << 16
        payloadLen |= UInt32(buffer[17]) << 24

        // Check payload size BEFORE trying to read it (R3.8)
        let maxPayloadBytes: UInt32 = 16 * 1024 * 1024
        guard payloadLen <= maxPayloadBytes else {
            throw HelperFrameError.oversizedPayload
        }

        // Check if we have the full frame
        let totalNeeded = 18 + Int(payloadLen)
        if buffer.count < totalNeeded {
            return nil
        }

        // We have a complete frame; decode and consume it
        let flags = buffer[5]
        let expectsReply = (flags & 1) != 0

        var corrID = UInt64(buffer[6])
        corrID |= UInt64(buffer[7]) << 8
        corrID |= UInt64(buffer[8]) << 16
        corrID |= UInt64(buffer[9]) << 24
        corrID |= UInt64(buffer[10]) << 32
        corrID |= UInt64(buffer[11]) << 40
        corrID |= UInt64(buffer[12]) << 48
        corrID |= UInt64(buffer[13]) << 56

        let payload = Data(buffer[18..<(18 + Int(payloadLen))])

        // Consume this frame from the buffer
        buffer = buffer.count > totalNeeded ? Data(buffer[totalNeeded...]) : Data()

        return HelperFrame(method: "", payload: payload, expectsReply: expectsReply, correlationID: corrID)
    }
}
