import Foundation

#if canImport(Glibc)
import Glibc

/// A Unix domain socket server for Linux that authenticates peers and serves requests.
///
/// This server:
/// - Binds to a filesystem-bound AF_UNIX socket
/// - Refuses to bind over a pre-existing path (R4.2)
/// - Sets socket and parent directory permissions (0660 socket, 0700 parent)
/// - Authenticates each peer via SO_PEERCRED on accept
/// - Decodes HelperFrames and passes them to a caller-supplied handler
/// - Encodes and sends framed replies
///
/// The server runs an accept loop on a dedicated Thread (never in a Task) to avoid
/// blocking the async runtime. Connection handlers execute on separate threads.
public final class UnixSocketServer: Sendable {
    /// Socket path (filesystem-bound, never abstract namespace).
    private let socketPath: String
    /// Parent directory for the socket (must be 0700).
    private let socketDir: String
    /// Authenticator for peer credentials.
    private let authenticator: LinuxPeerAuthenticator
    /// Handler for incoming requests.
    private let handler: @Sendable (String, Data) -> Data
    /// Server listening socket FD.
    private let serverLock = NSLock()
    private var serverFD: Int32 = -1
    private var isListeningFlag: Bool = false
    /// Accept thread and shutdown coordination.
    private let shutdownLock = NSLock()
    private var acceptThread: Thread?
    private var shouldShutdown: Bool = false

    /// Creates a Unix socket server.
    ///
    /// - Parameters:
    ///   - socketPath: Filesystem path for the socket (e.g., `/var/run/freesnitch/helper.sock`)
    ///   - expectedUID: Expected UID of peer, or nil to skip uid check (passed to authenticator)
    ///
    /// The parent directory of socketPath is created with 0700 permissions if it does not exist.
    /// If socketPath exists, an error is thrown (R4.2: refuse to bind over a pre-existing path).
    public convenience init(socketPath: String, expectedUID: uid_t? = nil, expectedGID: gid_t? = nil) throws {
        let authenticator = LinuxPeerAuthenticator(expectedUID: expectedUID, expectedGID: expectedGID)
        // Dummy handler; will be replaced by accept()
        try self.init(socketPath: socketPath, authenticator: authenticator, handler: { _, _ in Data() })
    }

    /// Creates a Unix socket server with custom authenticator and handler.
    ///
    /// - Parameters:
    ///   - socketPath: Filesystem path for the socket (e.g., `/var/run/freesnitch/helper.sock`)
    ///   - authenticator: Peer authenticator (L1: uid/gid check via SO_PEERCRED)
    ///   - handler: Handler function `(method: String, payload: Data) -> Data`
    ///
    /// The parent directory of socketPath is created with 0700 permissions if it does not exist.
    /// If socketPath exists, an error is thrown (R4.2: refuse to bind over a pre-existing path).
    public init(socketPath: String, authenticator: LinuxPeerAuthenticator, handler: @escaping @Sendable (String, Data) -> Data) throws {
        self.socketPath = socketPath
        self.authenticator = authenticator
        self.handler = handler

        // Extract parent directory
        let url = URL(fileURLWithPath: socketPath)
        self.socketDir = url.deletingLastPathComponent().path

        // Ensure parent directory exists with 0700
        try createSecureDirectory(socketDir)

        // Refuse to bind over a pre-existing path
        try refusePreexistingPath(socketPath)

        // Create and bind the socket
        try bind()
    }

    deinit {
        _ = try? shutdown()
    }

    // MARK: - Public API

    /// Blocking accept loop that handles connections until shutdown.
    /// Runs a dedicated thread internally; blocks the caller until shutdown or error.
    ///
    /// - Parameter handler: Called for each authenticated peer with (payload, correlationID, reply).
    ///   The handler must call reply() with the response payload.
    public func accept(handler: @escaping @Sendable (Data, UInt64, @escaping (Data) -> Void) -> Void) throws {
        // The lock guards serverFD, not the loop. Holding it across the accept
        // loop deadlocks shutdown(): the loop runs until shutdown is requested,
        // and shutdown() cannot request it because it blocks acquiring this
        // same lock. Take it only to read the descriptor, then let it go.
        serverLock.lock()
        let bound = serverFD >= 0
        serverLock.unlock()

        guard bound else {
            throw HelperTransportError.transportUnavailable("socket not bound")
        }

        isListeningFlag = true
        PSLog.debug(PSLog.helper, "unix socket server: listening on \(socketPath)")

        // Run accept loop (blocks)
        acceptLoopWithCallback(handler: handler)

        isListeningFlag = false
    }

    /// Starts the server accept loop on a dedicated thread.
    /// Returns immediately; the server runs in the background.
    public func start() {
        serverLock.lock()
        defer { serverLock.unlock() }

        guard serverFD >= 0 else {
            PSLog.error(PSLog.helper, "unix socket server: cannot start - not bound")
            return
        }

        let thread = Thread { [weak self] in
            self?.acceptLoop()
        }
        thread.name = "freesnitch.server.accept"
        thread.stackSize = 512 * 1024
        thread.start()

        shutdownLock.lock()
        self.acceptThread = thread
        shutdownLock.unlock()

        isListeningFlag = true
        PSLog.debug(PSLog.helper, "unix socket server: listening on \(socketPath)")
    }

    /// Gracefully shuts down the server.
    public func shutdown() throws {
        shutdownLock.lock()
        shouldShutdown = true
        shutdownLock.unlock()

        serverLock.lock()
        if serverFD >= 0 {
            // The accept loop is parked inside accept(), where a flag cannot
            // reach it: shouldShutdown is only consulted once accept returns,
            // and with no client connecting it never does. close() alone is
            // not enough either -- closing a descriptor another thread is
            // blocked on is undefined on Linux and the thread can stay parked,
            // which is exactly how this deadlocked. shutdown() does wake it,
            // so it has to come first. ENOTCONN is expected for a listening
            // socket and is not an error.
            _ = Glibc.shutdown(serverFD, Int32(SHUT_RDWR))
            close(serverFD)
            serverFD = -1
        }
        serverLock.unlock()

        isListeningFlag = false

        // Wait for accept thread to finish
        shutdownLock.lock()
        let thread = acceptThread
        acceptThread = nil
        shutdownLock.unlock()

        if let thread = thread {
            thread.cancel()
        }

        // Clean up socket file
        try? FileManager.default.removeItem(atPath: socketPath)

        PSLog.debug(PSLog.helper, "unix socket server: shut down")
    }

    // MARK: - Private: Binding

    private func createSecureDirectory(_ path: String) throws {
        let fm = FileManager.default

        // Check if it exists
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: path, isDirectory: &isDir) {
            guard isDir.boolValue else {
                throw HelperTransportError.transportUnavailable("socket parent is not a directory: \(path)")
            }
            // Already exists as a directory. Check/set permissions.
            do {
                let attrs = try fm.attributesOfItem(atPath: path)
                let mode = (attrs[.posixPermissions] as? NSNumber)?.int32Value ?? 0
                if (mode & 0o777) != 0o700 {
                    PSLog.error(PSLog.helper, "unix socket server: parent dir has permissive mode; refusing")
                    throw HelperTransportError.transportUnavailable("socket parent has insecure permissions")
                }
            } catch {
                PSLog.error(PSLog.helper, "unix socket server: cannot check parent directory permissions: \(error)")
                throw error
            }
            return
        }

        // Create it with 0700 (parent-only access)
        let mode: mode_t = 0o700
        let oldUmask = umask(0o077)
        defer { _ = umask(oldUmask) }

        do {
            try fm.createDirectory(atPath: path, withIntermediateDirectories: false, attributes: [.posixPermissions: NSNumber(value: mode)])
            PSLog.debug(PSLog.helper, "unix socket server: created secure directory: \(path)")
        } catch {
            PSLog.error(PSLog.helper, "unix socket server: cannot create parent directory: \(error)")
            throw error
        }
    }

    private func refusePreexistingPath(_ path: String) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: path) {
            PSLog.error(PSLog.helper, "unix socket server: refused to bind - path exists: \(path)")
            throw HelperTransportError.transportUnavailable("socket path already exists")
        }
    }

    private func bind() throws {
        // Create socket with SOCK_CLOEXEC
        let sockType = Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue)
        let fd = socket(AF_UNIX, sockType, 0)
        guard fd >= 0 else {
            let err = String(cString: strerror(errno))
            PSLog.error(PSLog.helper, "unix socket server: cannot create socket: \(err)")
            throw HelperTransportError.transportUnavailable("socket creation failed: \(err)")
        }

        defer {
            if serverFD < 0 {
                close(fd)
            }
        }

        // Set up the address
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = socketPath.utf8
        let maxPathLen = MemoryLayout<sockaddr_un>.size - MemoryLayout.offset(of: \sockaddr_un.sun_path)!
        guard pathBytes.count < maxPathLen else {
            PSLog.error(PSLog.helper, "unix socket server: socket path too long")
            throw HelperTransportError.transportUnavailable("socket path too long")
        }

        // Copy path into sun_path
        memcpy(&addr.sun_path, Array(pathBytes), pathBytes.count)

        // Set umask around bind to ensure socket is created 0660
        // With umask 0o117: 0o777 & ~0o117 = 0o660
        let oldUmask = umask(0o117)
        defer { _ = umask(oldUmask) }

        let addrPtr = withUnsafePointer(to: &addr) { ptr in
            UnsafeRawPointer(ptr).assumingMemoryBound(to: sockaddr.self)
        }
        let sockLen = socklen_t(MemoryLayout<sockaddr_un>.size)

        let bindResult = Glibc.bind(fd, addrPtr, sockLen)
        guard bindResult == 0 else {
            let err = String(cString: strerror(errno))
            PSLog.error(PSLog.helper, "unix socket server: bind failed: \(err)")
            throw HelperTransportError.transportUnavailable("bind failed: \(err)")
        }

        // Verify socket has 0660 permissions
        do {
            let fm = FileManager.default
            let attrs = try fm.attributesOfItem(atPath: socketPath)
            let mode = (attrs[.posixPermissions] as? NSNumber)?.int32Value ?? 0
            let perms = mode & 0o777
            if perms != 0o660 {
                PSLog.debug(PSLog.helper, "unix socket server: socket has mode \(String(perms, radix: 8)); expected 0660")
            }
        } catch {
            PSLog.debug(PSLog.helper, "unix socket server: cannot verify socket permissions: \(error)")
        }

        // Mark socket as listening
        let backlog: Int32 = 128
        let listenResult = Glibc.listen(fd, backlog)
        guard listenResult == 0 else {
            let err = String(cString: strerror(errno))
            PSLog.error(PSLog.helper, "unix socket server: listen failed: \(err)")
            throw HelperTransportError.transportUnavailable("listen failed: \(err)")
        }

        serverFD = fd
        PSLog.debug(PSLog.helper, "unix socket server: bound to \(socketPath)")
    }

    // MARK: - Private: Accept Loop

    /// Blocking accept loop with callback-based handler (runs on caller's thread).
    /// Blocks until shutdown or error.
    private func acceptLoopWithCallback(handler: @escaping @Sendable (Data, UInt64, @escaping (Data) -> Void) -> Void) {
        while true {
            shutdownLock.lock()
            let shouldStop = shouldShutdown
            shutdownLock.unlock()

            if shouldStop {
                break
            }

            serverLock.lock()
            let fd = serverFD
            serverLock.unlock()

            guard fd >= 0 else {
                break
            }

            // Accept a connection
            var peerAddr = sockaddr_un()
            var peerLen = socklen_t(MemoryLayout<sockaddr_un>.size)

            let connFD: Int32 = withUnsafeMutablePointer(to: &peerAddr) { addrPtr in
                let addr = UnsafeMutableRawPointer(addrPtr).assumingMemoryBound(to: sockaddr.self)
                return Glibc.accept(fd, addr, &peerLen)
            }

            guard connFD >= 0 else {
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
                    continue
                }
                if errno == EBADF {
                    // Server socket was closed (shutdown)
                    break
                }
                PSLog.error(PSLog.helper, "unix socket server: accept failed: \(String(cString: strerror(errno)))")
                continue
            }

            // Authenticate the peer
            guard authenticator.authenticate(fd: connFD) else {
                PSLog.error(PSLog.helper, "unix socket server: peer authentication failed")
                close(connFD)
                continue
            }

            // Handle the connection on a separate thread
            Thread {
                self.handleConnectionWithCallback(fd: connFD, handler: handler)
            }.start()
        }

        // Clean up
        serverLock.lock()
        if serverFD >= 0 {
            close(serverFD)
            serverFD = -1
        }
        serverLock.unlock()
    }

    /// Blocking accept loop (runs on dedicated thread, never in a Task).
    private func acceptLoop() {
        while true {
            shutdownLock.lock()
            let shouldStop = shouldShutdown
            shutdownLock.unlock()

            if shouldStop {
                break
            }

            serverLock.lock()
            let fd = serverFD
            serverLock.unlock()

            guard fd >= 0 else {
                break
            }

            // Accept a connection
            var peerAddr = sockaddr_un()
            var peerLen = socklen_t(MemoryLayout<sockaddr_un>.size)

            let connFD: Int32 = withUnsafeMutablePointer(to: &peerAddr) { addrPtr in
                let addr = UnsafeMutableRawPointer(addrPtr).assumingMemoryBound(to: sockaddr.self)
                return Glibc.accept(fd, addr, &peerLen)
            }

            guard connFD >= 0 else {
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
                    continue
                }
                if errno == EBADF {
                    // Server socket was closed (shutdown)
                    break
                }
                PSLog.error(PSLog.helper, "unix socket server: accept failed: \(String(cString: strerror(errno)))")
                continue
            }

            // Authenticate the peer
            guard authenticator.authenticate(fd: connFD) else {
                PSLog.error(PSLog.helper, "unix socket server: peer authentication failed")
                close(connFD)
                continue
            }

            // Handle the connection on a separate thread
            Thread {
                self.handleConnection(fd: connFD)
            }.start()
        }

        // Clean up
        serverLock.lock()
        if serverFD >= 0 {
            close(serverFD)
            serverFD = -1
        }
        serverLock.unlock()
    }

    // MARK: - Private: Connection Handling

    /// Handles a connection with callback-based handler.
    private func handleConnectionWithCallback(fd: Int32, handler: @Sendable (Data, UInt64, @escaping @Sendable (Data) -> Void) -> Void) {
        defer {
            close(fd)
        }

        let decoder = HelperFrameDecoder()
        var receiveBuffer = Data(capacity: 64 * 1024)

        // Set read timeout to 30 seconds
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        while true {
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = read(fd, &chunk, chunk.count)

            if n < 0 {
                if errno == EINTR {
                    continue
                }
                if errno == EWOULDBLOCK || errno == EAGAIN {
                    // Timeout or no data
                    break
                }
                PSLog.debug(PSLog.helper, "unix socket server: read error")
                break
            }

            if n == 0 {
                // Peer closed connection
                break
            }

            receiveBuffer.append(contentsOf: chunk[0..<n])

            // Try to decode frames
            do {
                while let frame = try decoder.feed(Data(receiveBuffer)) {
                    receiveBuffer = Data()

                    // Call handler with callback
                    if frame.expectsReply {
                        let corrID = frame.correlationID
                        handler(frame.payload, corrID) { responsePayload in
                            let reply = HelperFrame(
                                method: "reply",
                                payload: responsePayload,
                                expectsReply: false,
                                correlationID: corrID
                            )
                            let encoded = reply.encode()
                            _ = encoded.withUnsafeBytes { buf in
                                write(fd, buf.baseAddress!, encoded.count)
                            }
                        }
                    }
                }
            } catch {
                PSLog.debug(PSLog.helper, "unix socket server: frame decode error")
                break
            }
        }
    }

    private func handleConnection(fd: Int32) {
        defer {
            close(fd)
        }

        let decoder = HelperFrameDecoder()
        var receiveBuffer = Data(capacity: 64 * 1024)

        // Set read timeout to 30 seconds
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        while true {
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = read(fd, &chunk, chunk.count)

            if n < 0 {
                if errno == EINTR {
                    continue
                }
                if errno == EWOULDBLOCK || errno == EAGAIN {
                    // Timeout or no data
                    break
                }
                PSLog.debug(PSLog.helper, "unix socket server: read error")
                break
            }

            if n == 0 {
                // Peer closed connection
                break
            }

            receiveBuffer.append(contentsOf: chunk[0..<n])

            // Try to decode frames
            do {
                while let frame = try decoder.feed(Data(receiveBuffer)) {
                    receiveBuffer = Data()

                    // Handle the request
                    let responsePayload = handler(frame.method, frame.payload)

                    // Send reply if expected
                    if frame.expectsReply {
                        let reply = HelperFrame(
                            method: "reply",
                            payload: responsePayload,
                            expectsReply: false,
                            correlationID: frame.correlationID
                        )
                        let encoded = reply.encode()
                        _ = encoded.withUnsafeBytes { buf in
                            write(fd, buf.baseAddress!, encoded.count)
                        }
                    }
                }
            } catch {
                PSLog.debug(PSLog.helper, "unix socket server: frame decode error")
                break
            }
        }
    }
}

#endif
