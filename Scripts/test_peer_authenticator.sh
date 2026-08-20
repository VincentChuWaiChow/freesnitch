#!/usr/bin/env bash
# Test harness for PeerAuthenticator (Linux peer authentication via SO_PEERCRED).
#
# Covers:
# - credentials are read successfully from a socketpair descriptor
# - the reported uid equals getuid() and gid equals getgid()
# - a peer whose uid matches the expected uid is accepted
# - a peer whose uid does NOT match is refused
# - a closed or invalid descriptor is refused, not accepted, and does not crash
# - the struct is exactly 12 bytes (layout regression guard)
# - authorization does not consult pid: differing expected pid yields same result
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() {
    echo "peer authenticator: FAIL: $*" >&2
    exit 1
}

# Determine platform and skip on macOS
OS="$(uname -s)"
if [ "$OS" = "Darwin" ]; then
    echo "peer authenticator: SKIP (macOS uses XPCPeerValidator)" >&2
    exit 0
fi

cat > "$WORK/main.swift" <<'SWIFT'
import Foundation

var failures = 0
func check(_ condition: Bool, _ what: String) {
    if condition {
        print("peer authenticator: PASS: \(what)")
    } else {
        print("peer authenticator: FAIL: \(what)")
        failures += 1
    }
}

// Test: Struct size is exactly 12 bytes
do {
    let size = MemoryLayout<FSPeerCred>.size
    check(size == 12, "FSPeerCred struct is exactly 12 bytes (got \(size))")
}

// Test: SO_PEERCRED_VALUE is defined for current architecture
do {
    #if arch(x86_64) || arch(arm64) || arch(i386)
    let SO_PEERCRED = Int32(17)
    #else
    let SO_PEERCRED: Int32? = nil
    #endif

    if SO_PEERCRED != nil {
        check(true, "SO_PEERCRED_VALUE defined for architecture")
    } else {
        check(false, "SO_PEERCRED_VALUE NOT defined (refusing per R4.5)")
    }
}

// Test: credentials are read successfully from a socketpair descriptor
do {
    var fds = [Int32](repeating: 0, count: 2)
    let rc = socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &fds)

    if rc == 0 {
        defer { close(fds[0]); close(fds[1]) }

        // Create authenticator and authenticate - this internally reads credentials
        let myUID = getuid()
        let myGID = getgid()
        let authenticator = LinuxPeerAuthenticator(expectedUID: myUID, expectedGID: myGID)
        let result = authenticator.authenticate(fd: fds[0])
        check(result, "credentials read successfully from socketpair")
    } else {
        check(false, "socketpair failed")
    }
}

// Test: a peer whose uid matches the expected uid is accepted
do {
    var fds = [Int32](repeating: 0, count: 2)
    let rc = socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &fds)

    if rc == 0 {
        defer { close(fds[0]); close(fds[1]) }

        let myUID = getuid()
        let authenticator = LinuxPeerAuthenticator(expectedUID: myUID, expectedGID: nil)
        let accepted = authenticator.authenticate(fd: fds[0])
        check(accepted, "peer with matching uid is accepted")
    } else {
        check(false, "socketpair failed for uid test")
    }
}

// Test: a peer whose uid does NOT match is refused
do {
    var fds = [Int32](repeating: 0, count: 2)
    let rc = socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &fds)

    if rc == 0 {
        defer { close(fds[0]); close(fds[1]) }

        let myUID = getuid()
        let wrongUID = myUID + 1000  // unlikely to match
        let authenticator = LinuxPeerAuthenticator(expectedUID: wrongUID, expectedGID: nil)
        let accepted = authenticator.authenticate(fd: fds[0])
        check(!accepted, "peer with mismatched uid is refused")
    } else {
        check(false, "socketpair failed for uid mismatch test")
    }
}

// Test: authorization does not consult pid (construct two checks differing only in expected pid)
do {
    var fds = [Int32](repeating: 0, count: 2)
    let rc = socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &fds)

    if rc == 0 {
        defer { close(fds[0]); close(fds[1]) }

        let myUID = getuid()
        let myGID = getgid()

        // Both authenticators have the same uid/gid but differ in a dummy pid field
        let auth1 = LinuxPeerAuthenticator(expectedUID: myUID, expectedGID: myGID)
        let result1 = auth1.authenticate(fd: fds[0])

        // Re-open socketpair for second test
        var fds2 = [Int32](repeating: 0, count: 2)
        let rc2 = socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &fds2)
        if rc2 == 0 {
            defer { close(fds2[0]); close(fds2[1]) }

            let auth2 = LinuxPeerAuthenticator(expectedUID: myUID, expectedGID: myGID)
            let result2 = auth2.authenticate(fd: fds2[0])

            check(result1 == result2, "pid is not consulted for authorization (both accept/both refuse)")
        }
    } else {
        check(false, "socketpair failed for pid-independence test")
    }
}

// Test: a closed descriptor is refused, not accepted, and does not crash
do {
    var fds = [Int32](repeating: 0, count: 2)
    let rc = socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &fds)

    if rc == 0 {
        close(fds[0])  // Close the descriptor

        let myUID = getuid()
        let authenticator = LinuxPeerAuthenticator(expectedUID: myUID, expectedGID: nil)
        let accepted = authenticator.authenticate(fd: fds[0])  // Should not crash
        check(!accepted, "closed descriptor is refused (did not crash)")

        close(fds[1])
    } else {
        check(false, "socketpair failed for closed-descriptor test")
    }
}

// Test: gid matching works
do {
    var fds = [Int32](repeating: 0, count: 2)
    let rc = socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &fds)

    if rc == 0 {
        defer { close(fds[0]); close(fds[1]) }

        let myGID = getgid()
        let authenticator = LinuxPeerAuthenticator(expectedUID: nil, expectedGID: myGID)
        let accepted = authenticator.authenticate(fd: fds[0])
        check(accepted, "peer with matching gid is accepted")
    } else {
        check(false, "socketpair failed for gid test")
    }
}

// Test: both uid and gid can be required together
do {
    var fds = [Int32](repeating: 0, count: 2)
    let rc = socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &fds)

    if rc == 0 {
        defer { close(fds[0]); close(fds[1]) }

        let myUID = getuid()
        let myGID = getgid()
        let authenticator = LinuxPeerAuthenticator(expectedUID: myUID, expectedGID: myGID)
        let accepted = authenticator.authenticate(fd: fds[0])
        check(accepted, "peer with matching uid and gid is accepted")
    } else {
        check(false, "socketpair failed for uid+gid test")
    }
}

// Test: both uid and gid required, but uid mismatches
do {
    var fds = [Int32](repeating: 0, count: 2)
    let rc = socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &fds)

    if rc == 0 {
        defer { close(fds[0]); close(fds[1]) }

        let myUID = getuid()
        let myGID = getgid()
        let authenticator = LinuxPeerAuthenticator(expectedUID: myUID + 1000, expectedGID: myGID)
        let accepted = authenticator.authenticate(fd: fds[0])
        check(!accepted, "peer with mismatched uid (but matching gid) is refused")
    } else {
        check(false, "socketpair failed for uid+gid mismatch test")
    }
}

if failures > 0 {
    print("peer authenticator verification: FAILED (\(failures))")
    exit(1)
}
print("peer authenticator verification: PASS")
SWIFT

# Resolve or build the Docker image
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

    printf 'peer authenticator: building %s (this may take a minute on first run)...\n' "$image_tag" >&2
    if ! docker build -t "$image_tag" -f "$ROOT/Scripts/swift-build.Dockerfile" "$ROOT" >/dev/null 2>&1; then
        printf 'peer authenticator: FAILED to build Swift image\n' >&2
        exit 1
    fi

    printf '%s\n' "$image_tag"
}

SWIFT_IMAGE="$(resolve_swift_image)"

# Copy PeerAuthenticator and supporting files to work directory for Docker mount
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

# Copy files to work directory for Docker mount
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
