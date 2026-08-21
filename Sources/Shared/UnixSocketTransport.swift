import Foundation

#if canImport(Glibc)
import Glibc

/// A cross-platform transport for Unix domain sockets (Linux).
/// Frames messages using HelperFrame and correlates replies by ID (non-FIFO).
///
/// This transport connects to a filesystem-bound `AF_UNIX` / `SOCK_STREAM` socket
/// and sends/receives framed messages. Replies are matched by correlation ID,
/// allowing concurrent in-flight requests without blocking.
///
/// Enforces per-call timeouts and handles partial reads/writes, EINTR, SOCK_CLOEXEC,
/// and SIGPIPE gracefully.
public final class UnixSocketTransport: HelperTransport, Sendable {
    private let socketPath: String
    private let defaultTimeout: TimeInterval
    private let socketLock = NSLock()
    private var socketFD: Int32 = -1
    private var isConnectedFlag: Bool = false
    private var nextCorrelationID: UInt64 = 1
    private let replyLock = NSLock()
    private var pendingReplies: [UInt64: CheckedContinuation<Data, Error>] = [:]
    private var readerThread: Thread?

    /// Maximum payload size (16 MB, per R3.8).
    private let maxPayloadBytes: UInt32 = 16 * 1024 * 1024

    public var isConnected: Bool {
        socketLock.lock()
        defer { socketLock.unlock() }
        return isConnectedFlag && socketFD >= 0
    }

    /// Initializes a Unix socket transport from a filesystem path.
    ///
    /// - Parameters:
    ///   - socketPath: Filesystem path to the AF_UNIX socket (e.g., `/var/run/freesnitch/helper.sock`)
    ///   - timeout: Default timeout for all requests in seconds (default 15s)
    public init(socketPath: String, timeout: TimeInterval = 15) throws {
        self.socketPath = socketPath
        self.defaultTimeout = timeout

        try connect()
    }

    /// Internal initializer for a pre-connected file descriptor.
    /// Used for systemd socket activation and test harnesses.
    internal init(connectedFD: Int32, timeout: TimeInterval = 15) {
        self.socketPath = "(fd:\(connectedFD))"
        self.defaultTimeout = timeout
        self.socketFD = connectedFD
        self.isConnectedFlag = true

        // Start reader thread (not a Task — blocks on read() safely)
        startReaderThread()
    }

    deinit {
        disconnect()
    }

    // MARK: - HelperTransport Protocol

    public func request(_ method: String, payload: Data) async throws -> Data {
        return try await request(method, payload: payload, timeout: defaultTimeout)
    }

    /// Request-reply call with explicit timeout.
    public func request(_ method: String, payload: Data, timeout: TimeInterval) async throws -> Data {
        guard isConnected else {
            throw HelperTransportError.notConnected
        }

        let corrID = getNextCorrelationID()
        let frame = HelperFrame(method: method, payload: payload, expectsReply: true, correlationID: corrID)

        // Send the request
        try sendFrame(frame)

        // Wait for reply with per-call timeout
        return try await readReply(correlationID: corrID, timeout: timeout)
    }

    public func notify(_ method: String, payload: Data) throws {
        guard isConnected else {
            throw HelperTransportError.notConnected
        }

        let frame = HelperFrame(method: method, payload: payload, expectsReply: false, correlationID: 0)
        try sendFrame(frame)
    }

    // MARK: - Private Methods

    private func connect() throws {
        socketLock.lock()
        defer { socketLock.unlock() }

        // Create socket with SOCK_CLOEXEC
        let sockType = Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue)
        let fd = socket(AF_UNIX, sockType, 0)
        guard fd >= 0 else {
            throw HelperTransportError.transportUnavailable("socket creation failed: \(String(cString: strerror(errno)))")
        }

        defer {
            if socketFD < 0 {
                close(fd)
            }
        }

        // Set up the address
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = socketPath.utf8
        let maxPathLen = MemoryLayout<sockaddr_un>.size - MemoryLayout.offset(of: \sockaddr_un.sun_path)!
        guard pathBytes.count < maxPathLen else {
            throw HelperTransportError.transportUnavailable("socket path too long")
        }

        // Copy path into sun_path
        memcpy(&addr.sun_path, Array(pathBytes), pathBytes.count)

        // Connect to the socket
        let addrPtr = withUnsafePointer(to: &addr) { ptr in
            UnsafeRawPointer(ptr).assumingMemoryBound(to: sockaddr.self)
        }

        let sockLen = socklen_t(MemoryLayout<sockaddr_un>.size)

        // Handle EINTR on connect
        var retryCount = 0
        while true {
            let result = Glibc.connect(fd, addrPtr, sockLen)
            if result == 0 {
                break  // Success
            }

            if errno == EINTR {
                retryCount += 1
                guard retryCount < 10 else {
                    throw HelperTransportError.notConnected
                }
                continue
            }

            // Connection failed
            if errno == ENOENT || errno == ECONNREFUSED {
                throw HelperTransportError.notConnected
            }

            throw HelperTransportError.transportUnavailable(
                "connect failed: \(String(cString: strerror(errno)))"
            )
        }

        socketFD = fd
        isConnectedFlag = true

        // Start reader thread
        startReaderThread()
    }

    private func startReaderThread() {
        let thread = Thread { [weak self] in
            self?.readLoop()
        }
        thread.name = "freesnitch.transport.reader"
        thread.stackSize = 512 * 1024
        thread.start()
        readerThread = thread
    }

    private func disconnect() {
        socketLock.lock()
        defer { socketLock.unlock() }

        if socketFD >= 0 {
            close(socketFD)
            socketFD = -1
        }
        isConnectedFlag = false

        // Fail all pending replies
        replyLock.lock()
        defer { replyLock.unlock() }
        for (_, continuation) in pendingReplies {
            continuation.resume(throwing: HelperTransportError.notConnected)
        }
        pendingReplies.removeAll()

        readerThread = nil
    }

    private func sendFrame(_ frame: HelperFrame) throws {
        socketLock.lock()
        let fd = socketFD
        socketLock.unlock()

        guard fd >= 0 else {
            throw HelperTransportError.notConnected
        }

        let encoded = frame.encode()
        var sentBytes = 0

        while sentBytes < encoded.count {
            let toSend = Int32(encoded.count - sentBytes)
            let result = encoded.withUnsafeBytes { buf in
                #if os(Linux)
                // Use MSG_NOSIGNAL to avoid SIGPIPE on broken pipe
                Glibc.send(fd, buf.baseAddress! + sentBytes, Int(toSend), Int32(MSG_NOSIGNAL))
                #else
                write(fd, buf.baseAddress! + sentBytes, Int(toSend))
                #endif
            }

            if result < 0 {
                if errno == EINTR {
                    // Interrupted, retry
                    continue
                }
                if errno == EPIPE || errno == ECONNRESET {
                    disconnect()
                    throw HelperTransportError.notConnected
                }
                throw HelperTransportError.transportUnavailable(
                    "write failed: \(String(cString: strerror(errno)))"
                )
            }

            if result == 0 {
                // Socket closed
                disconnect()
                throw HelperTransportError.notConnected
            }

            sentBytes += Int(result)
        }
    }

    private func getNextCorrelationID() -> UInt64 {
        let id = nextCorrelationID
        nextCorrelationID += 1
        if nextCorrelationID == 0 {
            nextCorrelationID = 1  // Skip 0 (reserved for notify)
        }
        return id
    }

    /// Blocking read loop that runs on a dedicated thread.
    /// Never blocks the cooperative task pool.
    private func readLoop() {
        let decoder = HelperFrameDecoder()
        var receiveBuffer = Data(capacity: 64 * 1024)

        while true {
            socketLock.lock()
            let fd = socketFD
            socketLock.unlock()

            guard fd >= 0 else {
                break
            }

            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = read(fd, &chunk, chunk.count)

            if n < 0 {
                if errno == EINTR {
                    continue
                }
                disconnect()
                break
            }

            if n == 0 {
                // Connection closed by peer
                disconnect()
                break
            }

            receiveBuffer.append(contentsOf: chunk[0..<n])

            // Try to decode frames
            do {
                while let frame = try decoder.feed(Data(receiveBuffer)) {
                    receiveBuffer = Data()

                    // Deliver to the waiting request
                    replyLock.lock()
                    if let continuation = pendingReplies.removeValue(forKey: frame.correlationID) {
                        replyLock.unlock()
                        // Resume the continuation on its original executor
                        continuation.resume(returning: frame.payload)
                    } else {
                        replyLock.unlock()
                    }
                }
            } catch {
                disconnect()
                break
            }
        }
    }

    /// Suspends until the reply with this correlation id arrives, or the timeout
    /// elapses.
    ///
    /// The timeout resumes the continuation rather than racing it. That
    /// distinction is the whole reason this is not a task group: a continuation
    /// that is never resumed suspends its task forever, and
    /// `withCheckedThrowingContinuation` is not cancellation-aware, so
    /// cancelling the task around it does nothing. A group whose timeout child
    /// throws still waits for its other child, which would be parked on that
    /// continuation, and the wait never ends.
    ///
    /// The table is the arbiter. Whichever of the reader thread or the timeout
    /// removes the entry first is the one that resumes it; the other finds
    /// nothing and does nothing. Resuming a continuation twice is a crash, so
    /// the removal has to be the atomic step, under the lock.
    private func readReply(correlationID: UInt64, timeout: TimeInterval) async throws -> Data {
        return try await withCheckedThrowingContinuation { continuation in
            replyLock.lock()
            pendingReplies[correlationID] = continuation
            replyLock.unlock()

            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self else { return }
                self.replyLock.lock()
                let pending = self.pendingReplies.removeValue(forKey: correlationID)
                self.replyLock.unlock()
                pending?.resume(throwing: HelperTransportError.timedOut)
            }
        }
    }
}

#endif
