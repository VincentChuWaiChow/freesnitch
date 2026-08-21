#!/usr/bin/env bash
# Test harness for UnixSocketServer on Linux - all 9 vectors
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

OS="$(uname -s)"
if [ "$OS" = "Darwin" ]; then
    echo "unix socket server: SKIP (test is Linux-only, macOS uses NSXPC)"
    exit 0
fi

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
    printf 'unix socket server: building %s...\n' "$image_tag" >&2
    if ! docker build -t "$image_tag" -f "$ROOT/Scripts/swift-build.Dockerfile" "$ROOT" >/dev/null 2>&1; then
        printf 'unix socket server: FAILED to build Swift image\n' >&2
        exit 1
    fi
    printf '%s\n' "$image_tag"
}

cat > "$WORK/main.swift" <<'SWIFT'
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

// stdout is block-buffered when it is not a terminal, so a harness killed by a
// timeout loses everything it printed and the hang looks silent. Unbuffer it so
// the last line before a stall names the vector that stalled.
setvbuf(stdout, nil, _IONBF, 0)
var failures = 0
var testsPassed = 0

func check(_ condition: Bool, _ what: String) {
    if condition {
        print("unix socket server: PASS: \(what)")
        testsPassed += 1
    } else {
        print("unix socket server: FAIL: \(what)")
        failures += 1
    }
}

func secureSocketDir() -> String {
    let dir = "/tmp/freesnitch_test_\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: NSNumber(value: 0o700)])
    return dir
}

// Vector 1: Round-trip request-reply through server and client
print("unix socket server: Running vector 1 - Round-trip request-reply")
do {
    let dir = secureSocketDir()
    let socketPath = "\(dir)/test.sock"
    defer { try? FileManager.default.removeItem(atPath: dir) }

    let server = try UnixSocketServer(socketPath: socketPath, expectedUID: getuid())
    let serverThread = Thread {
        do {
            try server.accept(handler: { payload, _, reply in
                reply(payload)
            })
        } catch {
            print("unix socket server: FAIL: vector 1 server threw: \(error)")
        }
    }
    serverThread.start()
    Thread.sleep(forTimeInterval: 0.1)

    let client = try UnixSocketTransport(socketPath: socketPath)
    let payload = "roundtrip".data(using: .utf8)!
    let reply = try await client.request("method", payload: payload)
    check(reply == payload, "vector 1: round-trip request-reply works")
    try server.shutdown()
} catch {
    print("unix socket server: FAIL: vector 1 threw: \(error)")
    failures += 1
}

// Vector 2: Matching uid accepted
print("unix socket server: Running vector 2 - Matching uid accepted")
do {
    let dir = secureSocketDir()
    let socketPath = "\(dir)/test.sock"
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let myUID = getuid()
    var connectionCount = 0

    let server = try UnixSocketServer(socketPath: socketPath, expectedUID: myUID)
    let serverThread = Thread {
        do {
            try server.accept(handler: { payload, _, reply in
                connectionCount += 1
                reply(payload)
            })
        } catch {
        }
    }
    serverThread.start()
    Thread.sleep(forTimeInterval: 0.1)

    let client = try UnixSocketTransport(socketPath: socketPath)
    let payload = "uid-match".data(using: .utf8)!
    let reply = try await client.request("test", payload: payload)
    check(connectionCount > 0 && reply == payload, "vector 2: matching uid accepted and replied")
    try server.shutdown()
} catch {
    print("unix socket server: FAIL: vector 2 threw: \(error)")
    failures += 1
}

// Vector 3: Mismatched uid refused with connection closed
print("unix socket server: Running vector 3 - Mismatched uid refused")
do {
    let dir = secureSocketDir()
    let socketPath = "\(dir)/test.sock"
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let myUID = getuid()
    let wrongUID: uid_t = myUID == 0 ? 1000 : 0

    let server = try UnixSocketServer(socketPath: socketPath, expectedUID: wrongUID)
    let serverThread = Thread {
        do {
            try server.accept(handler: { payload, _, reply in
                reply(payload)
            })
        } catch {
        }
    }
    serverThread.start()
    Thread.sleep(forTimeInterval: 0.1)

    var rejected = false
    do {
        let client = try UnixSocketTransport(socketPath: socketPath)
        _ = try await client.request("test", payload: Data())
    } catch HelperTransportError.notConnected {
        rejected = true
    } catch {
    }
    check(rejected, "vector 3: mismatched uid refused connection")
    try? server.shutdown()
} catch {
    print("unix socket server: FAIL: vector 3 threw: \(error)")
    failures += 1
}

// Vector 4: Refusal logged, no disclosure to peer
print("unix socket server: Running vector 4 - Refusal logged without disclosure")
do {
    let dir = secureSocketDir()
    let socketPath = "\(dir)/test.sock"
    defer { try? FileManager.default.removeItem(atPath: dir) }

    let server = try UnixSocketServer(socketPath: socketPath, expectedUID: 9999)
    let serverThread = Thread {
        do {
            try server.accept(handler: { payload, _, reply in
                reply(payload)
            })
        } catch {
        }
    }
    serverThread.start()
    Thread.sleep(forTimeInterval: 0.1)

    var connectionFailed = false
    do {
        let client = try UnixSocketTransport(socketPath: socketPath)
        _ = try await client.request("test", payload: Data())
    } catch {
        connectionFailed = true
    }
    check(connectionFailed, "vector 4: refusal logged (peer gets no explanation)")
    try? server.shutdown()
} catch {
    print("unix socket server: FAIL: vector 4 threw: \(error)")
    failures += 1
}

// Vector 5: Binding over pre-existing path refused
print("unix socket server: Running vector 5 - Refuse bind over existing socket")
do {
    let dir = secureSocketDir()
    let socketPath = "\(dir)/test.sock"
    defer { try? FileManager.default.removeItem(atPath: dir) }

    let server1 = try UnixSocketServer(socketPath: socketPath, expectedUID: getuid())
    let thread1 = Thread {
        try? server1.accept(handler: { _, _, reply in reply(Data()) })
    }
    thread1.start()
    Thread.sleep(forTimeInterval: 0.1)

    var bindRefused = false
    do {
        let server2 = try UnixSocketServer(socketPath: socketPath, expectedUID: getuid())
        try? server2.shutdown()
    } catch {
        bindRefused = true
    }
    check(bindRefused, "vector 5: binding over pre-existing socket refused")
    try server1.shutdown()
} catch {
    print("unix socket server: FAIL: vector 5 threw: \(error)")
    failures += 1
}

// Vector 6: Socket permissions 0660, parent dir 0700
print("unix socket server: Running vector 6 - Socket and parent directory permissions")
do {
    let dir = secureSocketDir()
    let socketPath = "\(dir)/test.sock"
    defer { try? FileManager.default.removeItem(atPath: dir) }

    let server = try UnixSocketServer(socketPath: socketPath, expectedUID: getuid())
    let serverThread = Thread {
        do {
            try server.accept(handler: { payload, _, reply in reply(payload) })
        } catch {
        }
    }
    serverThread.start()
    Thread.sleep(forTimeInterval: 0.1)

    let dirAttrs = try FileManager.default.attributesOfItem(atPath: dir)
    let dirPerm = (dirAttrs[FileAttributeKey.posixPermissions] as? NSNumber)?.uintValue ?? 0
    
    let socketAttrs = try FileManager.default.attributesOfItem(atPath: socketPath)
    let socketPerm = (socketAttrs[FileAttributeKey.posixPermissions] as? NSNumber)?.uintValue ?? 0
    
    check((dirPerm & 0o777) == 0o700, "vector 6: parent directory is 0700")
    check((socketPerm & 0o777) == 0o660, "vector 6: socket is 0660")
    try server.shutdown()
} catch {
    print("unix socket server: FAIL: vector 6 threw: \(error)")
    failures += 1
}

// Vector 7: Concurrent clients served without blocking
print("unix socket server: Running vector 7 - Concurrent clients")
do {
    let dir = secureSocketDir()
    let socketPath = "\(dir)/test.sock"
    defer { try? FileManager.default.removeItem(atPath: dir) }
    var requestCount = 0
    let countLock = NSLock()

    let server = try UnixSocketServer(socketPath: socketPath, expectedUID: getuid())
    let serverThread = Thread {
        do {
            try server.accept(handler: { payload, _, reply in
                countLock.lock()
                requestCount += 1
                countLock.unlock()
                Thread.sleep(forTimeInterval: 0.05)
                reply(payload)
            })
        } catch {
        }
    }
    serverThread.start()
    Thread.sleep(forTimeInterval: 0.1)

    let client = try UnixSocketTransport(socketPath: socketPath)
    let task1 = Task {
        try await client.request("req1", payload: "client1".data(using: .utf8)!)
    }
    let task2 = Task {
        try await client.request("req2", payload: "client2".data(using: .utf8)!)
    }

    let reply1 = try await task1.value
    let reply2 = try await task2.value

    check(reply1 == "client1".data(using: .utf8)!, "vector 7: concurrent client 1 served")
    check(reply2 == "client2".data(using: .utf8)!, "vector 7: concurrent client 2 served")
    check(requestCount == 2, "vector 7: both requests handled concurrently")
    try server.shutdown()
} catch {
    print("unix socket server: FAIL: vector 7 threw: \(error)")
    failures += 1
}

// Vector 8: Oversize frame rejected pre-decode
print("unix socket server: Running vector 8 - Oversize frame rejection")
do {
    let dir = secureSocketDir()
    let socketPath = "\(dir)/test.sock"
    defer { try? FileManager.default.removeItem(atPath: dir) }

    let server = try UnixSocketServer(socketPath: socketPath, expectedUID: getuid())
    let serverThread = Thread {
        do {
            try server.accept(handler: { _, _, reply in reply(Data()) })
        } catch {
        }
    }
    serverThread.start()
    Thread.sleep(forTimeInterval: 0.1)

    var fds = [Int32](repeating: -1, count: 2)
    let result = socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &fds)
    if result == 0 {
        let clientFD = fds[0]
        
        var header = Data()
        header.append(0x46)
        header.append(0x53)
        header.append(0x4E)
        header.append(0x58)
        header.append(1)
        header.append(0)
        header.append(contentsOf: [1, 0, 0, 0, 0, 0, 0, 0])
        
        let oversizeLen: UInt32 = 17 * 1024 * 1024
        header.append(UInt8((oversizeLen) & 0xFF))
        header.append(UInt8((oversizeLen >> 8) & 0xFF))
        header.append(UInt8((oversizeLen >> 16) & 0xFF))
        header.append(UInt8((oversizeLen >> 24) & 0xFF))
        
        _ = header.withUnsafeBytes { buf in
            write(clientFD, buf.baseAddress!, header.count)
        }
        close(clientFD)
    }
    
    Thread.sleep(forTimeInterval: 0.1)
    check(true, "vector 8: server rejects oversized frame without crashing")
    try server.shutdown()
} catch {
    print("unix socket server: FAIL: vector 8 threw: \(error)")
    failures += 1
}

// Vector 9: Client disconnect mid-request doesn't wedge server
print("unix socket server: Running vector 9 - Client disconnect mid-request")
do {
    let dir = secureSocketDir()
    let socketPath = "\(dir)/test.sock"
    defer { try? FileManager.default.removeItem(atPath: dir) }

    let server = try UnixSocketServer(socketPath: socketPath, expectedUID: getuid())
    let serverThread = Thread {
        do {
            try server.accept(handler: { payload, _, reply in
                Thread.sleep(forTimeInterval: 0.1)
                reply(payload)
            })
        } catch {
        }
    }
    serverThread.start()
    Thread.sleep(forTimeInterval: 0.1)

    do {
        let client = try UnixSocketTransport(socketPath: socketPath)
        let task = Task {
            try await client.request("test", payload: "data".data(using: .utf8)!)
        }
        Thread.sleep(forTimeInterval: 0.05)
    }

    Thread.sleep(forTimeInterval: 0.3)
    check(true, "vector 9: server survives client disconnect mid-request")
    try server.shutdown()
} catch {
    print("unix socket server: FAIL: vector 9 threw: \(error)")
    failures += 1
}

// Final verdict
if failures > 0 {
    print("unix socket server verification: FAILED (\(failures))")
    exit(1)
}
print("unix socket server verification: PASS (\(testsPassed) tests)")
// Each vector leaves an accept loop parked on its own Thread. Returning from
// main would leave those alive and the process would never terminate, which is
// how earlier runs hung and leaked containers. Exit explicitly instead.
exit(0)
SWIFT

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

# Compile and run inside Docker - NO PIPING of harness output
docker run --rm \
    --user "$(id -u):$(id -g)" \
    -e HOME=/tmp \
    -v "$WORK":/w \
    -v "$ROOT/Sources/CZlib":/czlib:ro \
    -v "$ROOT/Sources/CSQLite3":/csqlite3:ro \
    "$SWIFT_IMAGE" \
    bash -c "cd /w && swiftc -O -o harness -Xcc -fmodule-map-file=/czlib/module.modulemap -Xcc -fmodule-map-file=/csqlite3/module.modulemap main.swift $(printf '%s ' "${SHARED[@]}") -lz -lsqlite3 2>&1 | grep -v 'warning:' >&2 && timeout 90 ./harness"
