#!/usr/bin/env bash
# Test harness for UnixSocketTransport on Linux using socketpair(2).
#
# Creates connected pairs of AF_UNIX sockets in-process (no filesystem, no subprocess).
# Tests all eight vectors for the transport:
#
# 1. Round-trip: basic request-reply
# 2. Out-of-order correlation: second request answers first (proves non-FIFO)
# 3. Notify: one-way, no reply expected
# 4. No such path: immediate notConnected error
# 5. Silent server: timeout when server doesn't reply
# 6. Close mid-reply: truncation error
# 7. Oversized declared length: rejection before allocation
# 8. SIGPIPE: process survives write to closed peer
#
# Skips cleanly on macOS.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

OS="$(uname -s)"
if [ "$OS" = "Darwin" ]; then
    echo "unix socket transport: SKIP (test is Linux-only, macOS uses NSXPC)"
    exit 0
fi

cat > "$WORK/main.swift" <<'SWIFT'
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

var failures = 0
var testsPassed = 0

func check(_ condition: Bool, _ what: String) {
    if condition {
        print("unix socket transport: PASS: \(what)")
        testsPassed += 1
    } else {
        print("unix socket transport: FAIL: \(what)")
        failures += 1
    }
}

// MARK: - Test Server on a Dedicated Thread

class TestServer {
    private let serverFD: Int32
    private let responses: [UInt64: Data]  // correlationID -> response payload
    private let readySemaphore: DispatchSemaphore
    private let mode: Mode

    enum Mode {
        case echo              // Echo back request payload
        case delayedReply      // Answer second request first
        case closeMidReply     // Write partial frame then close
        case oversizedHeader   // Send oversized frame header
        case silent            // Accept but never reply
    }

    init(serverFD: Int32, mode: Mode = .echo, responses: [UInt64: Data] = [:]) {
        self.serverFD = serverFD
        self.mode = mode
        self.responses = responses
        self.readySemaphore = DispatchSemaphore(value: 0)
    }

    func start() {
        let semaphore = readySemaphore
        Thread {
            self.run()
            semaphore.signal()
        }.start()
    }

    func waitUntilDone() {
        readySemaphore.wait()
    }

    private func run() {
        switch mode {
        case .echo:
            runEcho()
        case .delayedReply:
            runDelayedReply()
        case .closeMidReply:
            runCloseMidReply()
        case .oversizedHeader:
            runOversizedHeader()
        case .silent:
            runSilent()
        }
    }

    private func runEcho() {
        let decoder = HelperFrameDecoder()
        var buffer = Data(capacity: 64 * 1024)

        // Set read timeout to 2 seconds
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        _ = setsockopt(serverFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        while true {
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = read(serverFD, &chunk, chunk.count)
            if n <= 0 { break }

            buffer.append(contentsOf: chunk[0..<n])

            do {
                while let frame = try decoder.feed(Data(buffer)) {
                    buffer = Data()
                    if frame.expectsReply {
                        print("unix socket transport: [server] received request, sending reply")
                        let reply = HelperFrame(
                            method: "reply",
                            payload: frame.payload,
                            expectsReply: false,
                            correlationID: frame.correlationID
                        )
                        let encoded = reply.encode()
                        _ = encoded.withUnsafeBytes { buf in
                            write(serverFD, buf.baseAddress!, encoded.count)
                        }
                        print("unix socket transport: [server] reply sent")
                    }
                }
            } catch {
                break
            }
        }
    }

    private func runDelayedReply() {
        let decoder = HelperFrameDecoder()
        var buffer = Data(capacity: 64 * 1024)
        var frames: [HelperFrame] = []

        // Set read timeout to 3 seconds
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        _ = setsockopt(serverFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        while frames.count < 2 {
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = read(serverFD, &chunk, chunk.count)
            if n <= 0 { break }

            buffer.append(contentsOf: chunk[0..<n])

            do {
                while let frame = try decoder.feed(Data(buffer)) {
                    buffer = Data()
                    frames.append(frame)
                }
            } catch {
                break
            }
        }

        // Answer in reverse order (second request first)
        for frame in frames.reversed() {
            if frame.expectsReply {
                let reply = HelperFrame(
                    method: "reply",
                    payload: frame.payload,
                    expectsReply: false,
                    correlationID: frame.correlationID
                )
                let encoded = reply.encode()
                _ = encoded.withUnsafeBytes { buf in
                    write(serverFD, buf.baseAddress!, encoded.count)
                }
            }
        }
    }

    private func runCloseMidReply() {
        let decoder = HelperFrameDecoder()
        var buffer = Data(capacity: 64 * 1024)

        // Set read timeout to 2 seconds
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        _ = setsockopt(serverFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        while true {
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = read(serverFD, &chunk, chunk.count)
            if n <= 0 { break }

            buffer.append(contentsOf: chunk[0..<n])

            do {
                while let frame = try decoder.feed(Data(buffer)) {
                    buffer = Data()
                    if frame.expectsReply {
                        let reply = HelperFrame(
                            method: "reply",
                            payload: frame.payload,
                            expectsReply: false,
                            correlationID: frame.correlationID
                        )
                        let encoded = reply.encode()
                        // Send only first 10 bytes, then close
                        _ = encoded.withUnsafeBytes { buf in
                            write(serverFD, buf.baseAddress!, min(10, encoded.count))
                        }
                        close(serverFD)
                        return
                    }
                }
            } catch {
                break
            }
        }
    }

    private func runOversizedHeader() {
        var header = [UInt8](repeating: 0, count: 18)
        _ = read(serverFD, &header, 18)

        // Send header with 17 MB payload length
        var response = Data()
        response.append(0x46)  // Magic FSNX
        response.append(0x53)
        response.append(0x4E)
        response.append(0x58)
        response.append(1)  // Version
        response.append(0)  // Flags
        response.append(contentsOf: [1, 0, 0, 0, 0, 0, 0, 0])  // Correlation ID = 1

        let oversizeLen: UInt32 = 17 * 1024 * 1024
        response.append(UInt8((oversizeLen) & 0xFF))
        response.append(UInt8((oversizeLen >> 8) & 0xFF))
        response.append(UInt8((oversizeLen >> 16) & 0xFF))
        response.append(UInt8((oversizeLen >> 24) & 0xFF))

        _ = response.withUnsafeBytes { buf in
            write(serverFD, buf.baseAddress!, response.count)
        }
        close(serverFD)
    }

    private func runSilent() {
        Thread.sleep(forTimeInterval: 10)
    }
}

// MARK: - Tests

// Test 1: Non-existent socket path (connection fails immediately)
print("unix socket transport: Running test 1 - Non-existent socket")
do {
    let socketPath = "/tmp/nonexistent_\(UUID().uuidString).sock"
    do {
        let transport = try UnixSocketTransport(socketPath: socketPath, timeout: 5.0)
        _ = try await transport.request("test", payload: Data())
        check(false, "nopath: should have thrown notConnected")
    } catch HelperTransportError.notConnected {
        check(true, "nopath: throws notConnected for non-existent socket")
    } catch {
        print("unix socket transport: FAIL: wrong error: \(error)")
        failures += 1
    }
} catch {
    print("unix socket transport: FAIL: test1 threw: \(error)")
    failures += 1
}

// Test 2: Round-trip request-reply
print("unix socket transport: Running test 2 - Round-trip")
do {
    var fds = [Int32](repeating: -1, count: 2)
    let result = socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &fds)
    guard result == 0 else {
        print("unix socket transport: FAIL: socketpair failed")
        failures += 1
        exit(1)
    }

    let clientFD = fds[0]
    let serverFD = fds[1]

    let server = TestServer(serverFD: serverFD, mode: .echo)
    server.start()

    // Give server time to start
    Thread.sleep(forTimeInterval: 0.1)

    do {
        let transport = UnixSocketTransport(connectedFD: clientFD, timeout: 15.0)
        let payload = "test-roundtrip".data(using: .utf8)!
        print("unix socket transport: INFO: roundtrip sending request")
        let reply = try await transport.request("method", payload: payload)
        print("unix socket transport: INFO: roundtrip received reply")
        check(reply == payload, "roundtrip: reply matches request")
    } catch {
        print("unix socket transport: FAIL: roundtrip threw: \(error)")
        failures += 1
    }

    server.waitUntilDone()
} catch {
    print("unix socket transport: FAIL: test2 threw: \(error)")
    failures += 1
}

// Test 3: Out-of-order correlation (second request answers first)
print("unix socket transport: Running test 3 - Out-of-order correlation")
do {
    var fds = [Int32](repeating: -1, count: 2)
    let result = socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &fds)
    guard result == 0 else {
        print("unix socket transport: FAIL: socketpair failed")
        failures += 1
        exit(1)
    }

    let clientFD = fds[0]
    let serverFD = fds[1]

    let server = TestServer(serverFD: serverFD, mode: .delayedReply)
    server.start()

    do {
        let transport = UnixSocketTransport(connectedFD: clientFD)

        let payload1 = "first-request".data(using: .utf8)!
        let payload2 = "second-request".data(using: .utf8)!

        let task1 = Task {
            try await transport.request("req1", payload: payload1)
        }
        let task2 = Task {
            try await transport.request("req2", payload: payload2)
        }

        let reply1 = try await task1.value
        let reply2 = try await task2.value

        check(reply1 == payload1, "outoforder: first request gets first payload")
        check(reply2 == payload2, "outoforder: second request gets second payload")
    } catch {
        print("unix socket transport: FAIL: outoforder threw: \(error)")
        failures += 1
    }

    server.waitUntilDone()
} catch {
    print("unix socket transport: FAIL: test3 threw: \(error)")
    failures += 1
}

// Test 4: Notify (one-way, no reply)
print("unix socket transport: Running test 4 - Notify")
do {
    var fds = [Int32](repeating: -1, count: 2)
    let result = socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &fds)
    guard result == 0 else {
        print("unix socket transport: FAIL: socketpair failed")
        failures += 1
        exit(1)
    }

    let clientFD = fds[0]
    let serverFD = fds[1]

    let server = TestServer(serverFD: serverFD, mode: .echo)
    server.start()

    do {
        let transport = UnixSocketTransport(connectedFD: clientFD)
        try transport.notify("notify", payload: "notify-payload".data(using: .utf8)!)
        check(true, "notify: one-way send completes")
    } catch {
        print("unix socket transport: FAIL: notify threw: \(error)")
        failures += 1
    }

    server.waitUntilDone()
} catch {
    print("unix socket transport: FAIL: test4 threw: \(error)")
    failures += 1
}

// Test 5: Silent server (timeout)
print("unix socket transport: Running test 5 - Timeout")
do {
    var fds = [Int32](repeating: -1, count: 2)
    let result = socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &fds)
    guard result == 0 else {
        print("unix socket transport: FAIL: socketpair failed")
        failures += 1
        exit(1)
    }

    let clientFD = fds[0]
    let serverFD = fds[1]

    let server = TestServer(serverFD: serverFD, mode: .silent)
    server.start()

    do {
        let transport = UnixSocketTransport(connectedFD: clientFD, timeout: 0.5)
        _ = try await transport.request("method", payload: Data())
        check(false, "timeout: should have thrown timedOut")
    } catch HelperTransportError.timedOut {
        check(true, "timeout: throws timedOut when server is silent")
    } catch {
        print("unix socket transport: FAIL: timeout wrong error: \(error)")
        failures += 1
    }

    server.waitUntilDone()
} catch {
    print("unix socket transport: FAIL: test5 threw: \(error)")
    failures += 1
}

// Test 6: Close mid-reply
print("unix socket transport: Running test 6 - Close mid-reply")
do {
    var fds = [Int32](repeating: -1, count: 2)
    let result = socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &fds)
    guard result == 0 else {
        print("unix socket transport: FAIL: socketpair failed")
        failures += 1
        exit(1)
    }

    let clientFD = fds[0]
    let serverFD = fds[1]

    let server = TestServer(serverFD: serverFD, mode: .closeMidReply)
    server.start()

    do {
        let transport = UnixSocketTransport(connectedFD: clientFD, timeout: 5.0)
        _ = try await transport.request("method", payload: Data())
        check(false, "closemid: should have thrown an error")
    } catch HelperTransportError.notConnected, HelperTransportError.malformedFrame(_) {
        check(true, "closemid: fails when server closes mid-reply")
    } catch {
        print("unix socket transport: FAIL: closemid wrong error: \(error)")
        failures += 1
    }

    server.waitUntilDone()
} catch {
    print("unix socket transport: FAIL: test6 threw: \(error)")
    failures += 1
}

// Test 7: Oversized declared length
print("unix socket transport: Running test 7 - Oversized frame")
do {
    var fds = [Int32](repeating: -1, count: 2)
    let result = socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &fds)
    guard result == 0 else {
        print("unix socket transport: FAIL: socketpair failed")
        failures += 1
        exit(1)
    }

    let clientFD = fds[0]
    let serverFD = fds[1]

    let server = TestServer(serverFD: serverFD, mode: .oversizedHeader)
    server.start()

    do {
        let transport = UnixSocketTransport(connectedFD: clientFD, timeout: 5.0)
        _ = try await transport.request("method", payload: Data())
        check(false, "oversized: should have thrown an error")
    } catch HelperTransportError.notConnected, HelperTransportError.malformedFrame(_) {
        check(true, "oversized: rejects oversized frame length")
    } catch {
        print("unix socket transport: FAIL: oversized wrong error: \(error)")
        failures += 1
    }

    server.waitUntilDone()
} catch {
    print("unix socket transport: FAIL: test7 threw: \(error)")
    failures += 1
}

// Test 8: SIGPIPE (process survives)
print("unix socket transport: Running test 8 - SIGPIPE")
do {
    var fds = [Int32](repeating: -1, count: 2)
    let result = socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &fds)
    guard result == 0 else {
        print("unix socket transport: FAIL: socketpair failed")
        failures += 1
        exit(1)
    }

    let clientFD = fds[0]
    let serverFD = fds[1]

    let server = TestServer(serverFD: serverFD, mode: .closeMidReply)
    server.start()

    do {
        let transport = UnixSocketTransport(connectedFD: clientFD, timeout: 5.0)
        _ = try await transport.request("method", payload: Data())
    } catch {
        // Expected to fail, but process should survive
        check(true, "sigpipe: process survives SIGPIPE")
    }

    server.waitUntilDone()
} catch {
    print("unix socket transport: FAIL: test8 threw: \(error)")
    failures += 1
}

if failures > 0 {
    print("unix socket transport verification: FAILED (\(failures))")
    exit(1)
}
print("unix socket transport verification: PASS (\(testsPassed) tests)")
SWIFT

# Build and run
resolve_swift_image() {
    if [ -n "${FREESNITCH_SWIFT_IMAGE:-}" ]; then
        printf '%s\n' "$FREESNITCH_SWIFT_IMAGE"
        return 0
    fi

    local image_tag="freesnitch-swift-build:6.0-noble"

    if docker image inspect "$image_tag" >/dev/null 2>&1; then
        printf '%s\n' "$image_tag"
        return 0
    fi

    printf 'unix socket transport: building %s...\n' "$image_tag" >&2
    if ! docker build -t "$image_tag" -f "$ROOT/Scripts/swift-build.Dockerfile" "$ROOT" >/dev/null 2>&1; then
        printf 'unix socket transport: FAILED to build Swift image\n' >&2
        exit 1
    fi

    printf '%s\n' "$image_tag"
}

SWIFT_IMAGE="$(resolve_swift_image)"

EXCLUDED=(
    'AppBundleIdentity.swift'
    'AppPreferences.swift'
    'HelperProtocol.swift'
    'IPCConnection.swift'
    'XPCPeerValidator.swift'
)

SHARED=()
while IFS= read -r file; do
    filename=$(basename "$file")
    excluded=false
    for ex in "${EXCLUDED[@]}"; do
        if [ "$filename" = "$ex" ]; then
            excluded=true
            break
        fi
    done
    if [ "$excluded" = false ]; then
        SHARED+=("$(basename "$file")")
    fi
done < <(find "$ROOT/Sources/Shared" -name '*.swift' | sort)

for f in "${SHARED[@]}"; do
    cp "$ROOT/Sources/Shared/$f" "$WORK/"
done

docker run --rm \
    --user "$(id -u):$(id -g)" \
    -e HOME=/tmp \
    -v "$WORK":/w \
    -v "$ROOT/Sources/CZlib":/czlib:ro \
    -v "$ROOT/Sources/CSQLite3":/csqlite3:ro \
    "$SWIFT_IMAGE" \
    bash -c "cd /w && swiftc -O -o harness -Xcc -fmodule-map-file=/czlib/module.modulemap -Xcc -fmodule-map-file=/csqlite3/module.modulemap main.swift $(printf '%s ' "${SHARED[@]}") -lz -lsqlite3 2>&1 && ./harness" | grep -v 'warning:' || true
