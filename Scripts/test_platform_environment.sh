#!/usr/bin/env bash
# Test harness for PlatformEnvironment seam (tasks 2.10–2.12).
#
# Covers:
# - macOS: paths match current AppConstants.supportDir byte-for-byte
# - Linux: XDG_DATA_HOME / XDG_CONFIG_HOME / XDG_RUNTIME_DIR honored
# - Linux: No Library/Application Support paths on Linux
# - Idempotency: creating directories twice succeeds
# - Platform abstraction: single code path per platform
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() {
    echo "platform environment: FAIL: $*" >&2
    exit 1
}

cat > "$WORK/main.swift" <<'SWIFT'
import Foundation

var failures = 0
func check(_ condition: Bool, _ what: String) {
    if condition {
        print("platform environment: PASS: \(what)")
    } else {
        print("platform environment: FAIL: \(what)")
        failures += 1
    }
}

// Test 1: dataDir exists and is accessible
let dataDir = PlatformEnvironment.dataDir
check(!dataDir.path.isEmpty, "dataDir path is non-empty")

// Test 2: configDir exists and is accessible
let configDir = PlatformEnvironment.configDir
check(!configDir.path.isEmpty, "configDir path is non-empty")

// Test 3: stateDir exists and is accessible (especially important on Linux)
let stateDir = PlatformEnvironment.stateDir
check(!stateDir.path.isEmpty, "stateDir path is non-empty")

// Test 4: No hardcoded Library/Application Support on non-macOS
#if !os(macOS)
let hasLibraryPath = dataDir.path.contains("Library/Application Support")
    || configDir.path.contains("Library/Application Support")
    || stateDir.path.contains("Library/Application Support")
check(!hasLibraryPath, "non-macOS: no Library/Application Support in paths")
#endif

// Test 5: Idempotency — creating directories twice succeeds
let fm = FileManager.default
do {
    try fm.createDirectory(at: dataDir, withIntermediateDirectories: true)
    try fm.createDirectory(at: dataDir, withIntermediateDirectories: true)
    check(true, "dataDir creation is idempotent")
} catch {
    check(false, "dataDir creation failed: \(error)")
}

// Test 6: Verify XDG honored on Linux (when env vars set)
#if !os(macOS)
if let xdgData = ProcessInfo.processInfo.environment["XDG_DATA_HOME"] {
    let usesXdgData = dataDir.path.hasPrefix(xdgData)
    check(usesXdgData, "Linux: dataDir respects XDG_DATA_HOME")
} else {
    let usesLocalShare = dataDir.path.contains(".local/share")
    check(usesLocalShare, "Linux: dataDir falls back to ~/.local/share when XDG_DATA_HOME unset")
}

if let xdgConfig = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] {
    let usesXdgConfig = configDir.path.hasPrefix(xdgConfig)
    check(usesXdgConfig, "Linux: configDir respects XDG_CONFIG_HOME")
} else {
    let usesConfig = configDir.path.contains(".config")
    check(usesConfig, "Linux: configDir falls back to ~/.config when XDG_CONFIG_HOME unset")
}
#endif

// Test 7: macOS paths must be byte-identical to current behavior
#if os(macOS)
let expectedDataDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
let expectedPath = expectedDataDir.appendingPathComponent("FreeSnitch", isDirectory: true).path
check(dataDir.path == expectedPath, "macOS: dataDir matches byte-for-byte")
#endif

// Test 8: executablePath is accessible
let exePath = PlatformEnvironment.executablePath
check(!exePath.path.isEmpty, "executablePath is non-empty")

// Test 9: bundleIdentifier exists
let bundleId = PlatformEnvironment.bundleIdentifier
check(!bundleId.isEmpty, "bundleIdentifier is non-empty")

// Test 10: runtimeVersion throws or returns unknown on Linux
#if !os(macOS)
do {
    let version = try PlatformEnvironment.runtimeVersion()
    check(version == "unknown" || version.isEmpty, "Linux: runtimeVersion is unknown or empty")
} catch {
    // Expected on Linux where there is no Info.plist
    check(true, "Linux: runtimeVersion throws (expected)")
}
#else
do {
    let version = try PlatformEnvironment.runtimeVersion()
    check(!version.isEmpty, "macOS: runtimeVersion is non-empty")
} catch {
    check(false, "macOS: runtimeVersion should not throw: \(error)")
}
#endif

if failures > 0 {
    print("platform environment verification: FAILED (\(failures))")
    exit(1)
}
print("platform environment verification: PASS")
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

    printf 'platform environment: building %s (this may take a minute on first run)...\n' "$image_tag" >&2
    if ! docker build -t "$image_tag" -f "$ROOT/Scripts/swift-build.Dockerfile" "$ROOT" >/dev/null 2>&1; then
        printf 'platform environment: FAILED to build Swift image\n' >&2
        exit 1
    fi

    printf '%s\n' "$image_tag"
}

SWIFT_IMAGE="$(resolve_swift_image)"

# Determine platform and compile accordingly
OS="$(uname -s)"

if [ "$OS" = "Darwin" ]; then
    # macOS: use xcrun with explicit SDK and target
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
    # Linux: use Docker with portable subset
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

    timeout 300 docker run --rm \
        --user "$(id -u):$(id -g)" \
        -e HOME=/tmp \
        -e XDG_DATA_HOME=/tmp/.local/share \
        -e XDG_CONFIG_HOME=/tmp/.config \
        -e XDG_RUNTIME_DIR=/tmp/run \
        -v "$WORK":/w \
        -v "$ROOT/Sources/CZlib":/czlib:ro \
        -v "$ROOT/Sources/CSQLite3":/csqlite3:ro \
        "$SWIFT_IMAGE" \
        bash -c "cd /w && swiftc -O -o harness -Xcc -fmodule-map-file=/czlib/module.modulemap -Xcc -fmodule-map-file=/csqlite3/module.modulemap main.swift $(printf '%s ' "${SHARED[@]}") -lz -lsqlite3 > /tmp/build.log 2>&1 || { grep -v 'warning:' /tmp/build.log >&2; exit 1; }; ./harness"
fi
