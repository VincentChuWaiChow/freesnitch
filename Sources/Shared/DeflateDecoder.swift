// Abstracts DEFLATE (RFC 1951) decoding across Darwin and Glibc.
// Both implementations receive raw DEFLATE (not gzip-wrapped) after the caller
// has manually stripped the gzip RFC 1952 header. Input and output buffer management
// is semantically identical: the processor updates avail_in/avail_out in place,
// and the caller subtracts these values from buffer pointers after each process.

#if canImport(Darwin)
import Darwin

// MARK: - Darwin Compression Framework

final class DeflateDecoder {
    private var stream = compression_stream()
    private var streamInitialized = false

    func initialize() throws {
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw IPGeoCache.GeoError("cannot start the DEFLATE decoder")
        }
        streamInitialized = true
    }

    func process(
        inputPtr: UnsafeMutablePointer<UInt8>,
        inputSize: inout Int,
        outputPtr: UnsafeMutablePointer<UInt8>,
        outputSize: inout Int,
        finalize: Bool
    ) -> DecoderStatus {
        stream.src_ptr = UnsafePointer(inputPtr)
        stream.src_size = inputSize
        stream.dst_ptr = outputPtr
        stream.dst_size = outputSize

        let flags = finalize ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
        let status = compression_stream_process(&stream, flags)

        inputSize = stream.src_size
        outputSize = stream.dst_size

        switch status {
        case COMPRESSION_STATUS_OK:
            return .ok
        case COMPRESSION_STATUS_END:
            return .end
        default:
            return .error
        }
    }

    deinit {
        if streamInitialized {
            compression_stream_destroy(&stream)
        }
    }
}

#elseif canImport(Glibc)
import CZlib
import Glibc

// MARK: - Glibc zlib

final class DeflateDecoder {
    private var stream = z_stream()
    private var streamInitialized = false

    func initialize() throws {
        // Raw DEFLATE: -MAX_WBITS tells zlib to skip the zlib wrapper (2-byte header).
        // We already stripped the gzip wrapper before this call, so we want raw DEFLATE only.
        let result = inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard result == Z_OK else {
            throw IPGeoCache.GeoError("cannot start the DEFLATE decoder")
        }
        streamInitialized = true
    }

    func process(
        inputPtr: UnsafeMutablePointer<UInt8>,
        inputSize: inout Int,
        outputPtr: UnsafeMutablePointer<UInt8>,
        outputSize: inout Int,
        finalize: Bool
    ) -> DecoderStatus {
        stream.next_in = inputPtr
        stream.avail_in = UInt32(inputSize)
        stream.next_out = outputPtr
        stream.avail_out = UInt32(outputSize)

        let flush = finalize ? Z_FINISH : Z_NO_FLUSH
        let status = inflate(&stream, flush)

        inputSize = Int(stream.avail_in)
        outputSize = Int(stream.avail_out)

        switch status {
        case Z_OK:
            return .ok
        case Z_STREAM_END:
            return .end
        default:
            return .error
        }
    }

    deinit {
        if streamInitialized {
            inflateEnd(&stream)
        }
    }
}

#else
#error("DeflateDecoder: unsupported platform")
#endif

// MARK: - Common Status Enum

enum DecoderStatus {
    case ok       // Decoder is still processing, but available output is exhausted
    case end      // Decompression complete
    case error    // Corrupt data or unrecoverable error
}
