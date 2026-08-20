import Foundation

/// The transport seam for cross-platform IPC communication.
/// On macOS, implementations use NSXPC. On Linux/Windows, implementations use framed sockets.
///
/// All parameters and replies are encoded as JSON via FreeSnitchWireCodec.
/// The transport layer is binary-agnostic and never decodes the payload itself.
public protocol HelperTransport: Sendable {
    /// Request-reply call. Blocks until a reply arrives or timeout.
    /// Timeout is enforced per-call; caller must retry on timeout.
    /// The payload and reply are both opaque Data; encoding/decoding is the caller's responsibility.
    func request(_ method: String, payload: Data) async throws -> Data

    /// Fire-and-forget notification. Does not wait for a reply.
    /// Errors are logged; caller does not receive failure feedback.
    func notify(_ method: String, payload: Data) throws

    /// True if the transport is currently connected or ready to send.
    var isConnected: Bool { get }
}

/// Errors that can be thrown by transport implementations.
public enum HelperTransportError: LocalizedError, Equatable, Sendable {
    case notConnected
    case timedOut
    case oversizedFrame
    case malformedFrame(String)
    case transportUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Transport is not connected."
        case .timedOut:
            return "Request timed out."
        case .oversizedFrame:
            return "Frame exceeds maximum size."
        case .malformedFrame(let reason):
            return "Malformed frame: \(reason)."
        case .transportUnavailable(let reason):
            return "Transport is unavailable: \(reason)."
        }
    }
}
