#!/usr/bin/env bash
# Regression harness for SEC-001.
#
# RuleMatcher uses bare hasPrefix() without path-boundary checks at two sites,
# causing /usr/bin/foo to wrongly match /usr/bin/foobar. This test drives both
# entry points — the public matches(rule:connection:) method, and the internal
# decision path via PreparedRule.matches.
#
# A path rule must match only its exact path and its children, never a sibling
# with the same prefix. Test vectors cover exact matches, boundary violations
# (suffix without separator), and directory traversal (child paths).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/main.swift" <<'SWIFT'
import Foundation

var failures = 0
func check(_ condition: Bool, _ what: String) {
    if condition {
        print("rule path scope: PASS: \(what)")
    } else {
        print("rule path scope: FAIL: \(what)")
        failures += 1
    }
}

func connection(processPath: String = "/Applications/Demo.app/Contents/MacOS/Demo",
                bundleId: String = "com.example.demo") -> Connection {
    Connection(pid: 501,
               processName: "Demo",
               processPath: processPath,
               processBundleId: bundleId,
               remoteHost: "example.com",
               remoteIP: "203.0.113.10",
               remotePort: 443,
               direction: .outgoing)
}

let matcher = RuleMatcher()

// Test vector 1: exact match must match
let rule1 = Rule(processBundleId: "com.example.demo",
                processPath: "/usr/bin/foo",
                processName: "foo",
                remoteHost: nil,
                remoteIP: nil,
                remotePort: nil,
                direction: .outgoing,
                action: .allow,
                scope: .process,
                priority: 100)
let conn1 = connection(processPath: "/usr/bin/foo")
check(matcher.matches(rule: rule1, connection: conn1),
      "exact path match: /usr/bin/foo matches /usr/bin/foo (direct)")
check(matcher.decision(for: conn1, rules: [rule1], defaultMode: .alert) == .allow,
      "exact path match: /usr/bin/foo matches /usr/bin/foo (via decision)")

// Test vector 2: prefix without boundary (foo vs foobar) must NOT match
let rule2 = Rule(processBundleId: "com.example.demo",
                processPath: "/usr/bin/foo",
                processName: "foo",
                remoteHost: nil,
                remoteIP: nil,
                remotePort: nil,
                direction: .outgoing,
                action: .allow,
                scope: .process,
                priority: 100)
let conn2 = connection(processPath: "/usr/bin/foobar")
check(!matcher.matches(rule: rule2, connection: conn2),
      "boundary violation: /usr/bin/foo must NOT match /usr/bin/foobar (direct)")
check(matcher.decision(for: conn2, rules: [rule2], defaultMode: .alert) != .allow,
      "boundary violation: /usr/bin/foo must NOT match /usr/bin/foobar (via decision)")

// Test vector 3: prefix with dash boundary must NOT match
let rule3 = Rule(processBundleId: "com.example.demo",
                processPath: "/usr/bin/foo",
                processName: "foo",
                remoteHost: nil,
                remoteIP: nil,
                remotePort: nil,
                direction: .outgoing,
                action: .allow,
                scope: .process,
                priority: 100)
let conn3 = connection(processPath: "/usr/bin/foo-evil")
check(!matcher.matches(rule: rule3, connection: conn3),
      "boundary violation: /usr/bin/foo must NOT match /usr/bin/foo-evil (direct)")
check(matcher.decision(for: conn3, rules: [rule3], defaultMode: .alert) != .allow,
      "boundary violation: /usr/bin/foo must NOT match /usr/bin/foo-evil (via decision)")

// Test vector 4: prefix with dot boundary must NOT match
let rule4 = Rule(processBundleId: "com.example.demo",
                processPath: "/usr/bin/foo",
                processName: "foo",
                remoteHost: nil,
                remoteIP: nil,
                remotePort: nil,
                direction: .outgoing,
                action: .allow,
                scope: .process,
                priority: 100)
let conn4 = connection(processPath: "/usr/bin/foo.backup")
check(!matcher.matches(rule: rule4, connection: conn4),
      "boundary violation: /usr/bin/foo must NOT match /usr/bin/foo.backup (direct)")
check(matcher.decision(for: conn4, rules: [rule4], defaultMode: .alert) != .allow,
      "boundary violation: /usr/bin/foo must NOT match /usr/bin/foo.backup (via decision)")

// Test vector 5: child path must match (directory semantics)
let rule5 = Rule(processBundleId: "com.example.demo",
                processPath: "/usr/bin/foo",
                processName: "foo",
                remoteHost: nil,
                remoteIP: nil,
                remotePort: nil,
                direction: .outgoing,
                action: .allow,
                scope: .process,
                priority: 100)
let conn5 = connection(processPath: "/usr/bin/foo/child")
check(matcher.matches(rule: rule5, connection: conn5),
      "directory semantics: /usr/bin/foo must match /usr/bin/foo/child (direct)")
check(matcher.decision(for: conn5, rules: [rule5], defaultMode: .alert) == .allow,
      "directory semantics: /usr/bin/foo must match /usr/bin/foo/child (via decision)")

// Test vector 6: app bundle extension must NOT match
let rule6 = Rule(processBundleId: "com.example.safari",
                processPath: "/Applications/Safari.app",
                processName: "Safari",
                remoteHost: nil,
                remoteIP: nil,
                remotePort: nil,
                direction: .outgoing,
                action: .allow,
                scope: .process,
                priority: 100)
let conn6 = connection(processPath: "/Applications/Safari.app.evil/x", bundleId: "com.example.safari")
check(!matcher.matches(rule: rule6, connection: conn6),
      "bundle boundary: /Applications/Safari.app must NOT match /Applications/Safari.app.evil/x (direct)")
check(matcher.decision(for: conn6, rules: [rule6], defaultMode: .alert) != .allow,
      "bundle boundary: /Applications/Safari.app must NOT match /Applications/Safari.app.evil/x (via decision)")

// Test vector 7: app bundle contents must match
let rule7 = Rule(processBundleId: "com.example.safari",
                processPath: "/Applications/Safari.app",
                processName: "Safari",
                remoteHost: nil,
                remoteIP: nil,
                remotePort: nil,
                direction: .outgoing,
                action: .allow,
                scope: .process,
                priority: 100)
let conn7 = connection(processPath: "/Applications/Safari.app/Contents/MacOS/Safari", bundleId: "com.example.safari")
check(matcher.matches(rule: rule7, connection: conn7),
      "app bundle contents: /Applications/Safari.app must match /Applications/Safari.app/Contents/MacOS/Safari (direct)")
check(matcher.decision(for: conn7, rules: [rule7], defaultMode: .alert) == .allow,
      "app bundle contents: /Applications/Safari.app must match /Applications/Safari.app/Contents/MacOS/Safari (via decision)")

// Test vector 8: trailing-slash rule must NOT match sibling with same prefix
let rule8 = Rule(processBundleId: "com.example.demo",
                processPath: "/usr/bin/foo/",
                processName: "foo",
                remoteHost: nil,
                remoteIP: nil,
                remotePort: nil,
                direction: .outgoing,
                action: .allow,
                scope: .process,
                priority: 100)
let conn8 = connection(processPath: "/usr/bin/foobar")
check(!matcher.matches(rule: rule8, connection: conn8),
      "trailing-slash boundary: /usr/bin/foo/ must NOT match /usr/bin/foobar (direct)")
check(matcher.decision(for: conn8, rules: [rule8], defaultMode: .alert) != .allow,
      "trailing-slash boundary: /usr/bin/foo/ must NOT match /usr/bin/foobar (via decision)")

// Test vector 9: trailing-slash rule must match children
let rule9 = Rule(processBundleId: "com.example.demo",
                processPath: "/usr/bin/foo/",
                processName: "foo",
                remoteHost: nil,
                remoteIP: nil,
                remotePort: nil,
                direction: .outgoing,
                action: .allow,
                scope: .process,
                priority: 100)
let conn9 = connection(processPath: "/usr/bin/foo/child")
check(matcher.matches(rule: rule9, connection: conn9),
      "trailing-slash directory: /usr/bin/foo/ must match /usr/bin/foo/child (direct)")
check(matcher.decision(for: conn9, rules: [rule9], defaultMode: .alert) == .allow,
      "trailing-slash directory: /usr/bin/foo/ must match /usr/bin/foo/child (via decision)")

if failures > 0 {
    print("rule path scope verification: FAILED (\(failures))")
    exit(1)
}
print("rule path scope verification: PASS")
SWIFT

# Resolve or build the Docker image (mirrors check_portable_core.sh).
resolve_swift_image() {
    if [ -n "${FREESNITCH_SWIFT_IMAGE:-}" ]; then
        printf '%s\n' "$FREESNITCH_SWIFT_IMAGE"
        return 0
    fi

    local image_tag="freesnitch-swift-build:6.0-noble"

    # Check if the image already exists locally.
    if docker image inspect "$image_tag" >/dev/null 2>&1; then
        printf '%s\n' "$image_tag"
        return 0
    fi

    # Image does not exist; build it from the Dockerfile.
    printf 'rule path scope: building %s (this may take a minute on first run)...\n' "$image_tag" >&2
    if ! docker build -t "$image_tag" -f "$ROOT/Scripts/swift-build.Dockerfile" "$ROOT" >/dev/null 2>&1; then
        printf 'rule path scope: FAILED to build Swift image\n' >&2
        exit 1
    fi

    printf '%s\n' "$image_tag"
}

SWIFT_IMAGE="$(resolve_swift_image)"

# Determine platform and compile accordingly
OS="$(uname -s)"

if [ "$OS" = "Darwin" ]; then
    # macOS: use xcrun with explicit SDK and target, all Shared files
    SHARED=()
    while IFS= read -r file; do SHARED+=("$file"); done < <(find "$ROOT/Sources/Shared" -name '*.swift' | sort)

    xcrun swiftc -O \
        -sdk "$(xcrun --show-sdk-path)" \
        -target arm64-apple-macos13.0 \
        -o "$WORK/harness" \
        "$WORK/main.swift" "${SHARED[@]}" \
        -lsqlite3 2>&1 | grep -v 'warning:' || true

    "$WORK/harness"
else
    # Linux: use Docker with portable subset (exclude Apple-only dependencies and cascade failures)
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
        bash -c "cd /w && swiftc -O -o harness -Xcc -fmodule-map-file=/czlib/module.modulemap -Xcc -fmodule-map-file=/csqlite3/module.modulemap main.swift $(printf '%s ' "${SHARED[@]}") -lz -lsqlite3 2>&1 && ./harness" | grep -v 'warning:'
fi
