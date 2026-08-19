#!/bin/bash
# Iterative portability check for Sources/Shared.
#
# Swift's type checker aborts after the first file that produces errors.
# This script iteratively removes the first erroring file and recompiles
# until the set is clean, classifying failures as real blockers (missing
# modules/symbols not in the codebase) or cascade failures (missing symbols
# that are declared elsewhere in Sources/Shared).
#
# Requirements: R2.4, R8.5 — regression gate for Apple-only dependencies
# entering the portable core.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() {
    printf 'portable core check: %s\n' "$1" >&2
    exit 1
}

# Toolchain selection: non-Darwin native swiftc, or Docker.
# macOS must use Docker to avoid reporting everything as portable.
select_toolchain() {
    local os
    os="$(uname -s)"

    if [ "$os" != "Darwin" ] && command -v swiftc &>/dev/null; then
        printf 'native\n'
        return 0
    fi

    if command -v docker &>/dev/null && docker ps &>/dev/null; then
        printf 'docker\n'
        return 0
    fi

    fail "no toolchain: native swiftc (non-Darwin) or docker required"
}

TOOLCHAIN="$(select_toolchain)"

# Hardcoded expected blockers, verified against Swift 6.0.3 on Linux.
# Update this list as Phase 1 and 2 land. Never grow without a design decision.
# When a file in this list compiles clean, it's progress — report but don't fail.
EXPECTED_BLOCKERS=(
    'AppBundleIdentity.swift'
    'IPGeo.swift'
    'RuleStore.swift'
)

# Compile with the selected toolchain. Output raw stderr/stdout.
#
# Both branches swallow the exit status because swiftc exits non-zero whenever
# it finds type errors, which is the normal case here. That makes a compiler
# that never ran indistinguishable from a clean compile, so the toolchain is
# proven separately by preflight_toolchain() before the sweep starts.
compile() {
    local files_arg=("$@")

    if [ "$TOOLCHAIN" = "docker" ]; then
        docker run --rm \
            --user "$(id -u):$(id -g)" \
            -e HOME=/tmp \
            -v "$WORK":/w \
            "${FREESNITCH_SWIFT_IMAGE:-swift:6.0-noble}" \
            bash -c "swiftc -typecheck /w/*.swift 2>&1" || true
    else
        swiftc -typecheck "${files_arg[@]}" 2>&1 || true
    fi
}

# Prove the toolchain can actually compile before trusting any silence from it.
#
# Without this the gate inverts: a missing image or a stopped Docker daemon
# produces no output, no output contains no "error:", and the sweep concludes
# every file is portable and exits 0. CI then goes green having checked nothing,
# which is worse than having no gate at all because it manufactures confidence.
preflight_toolchain() {
    local probe="$WORK/.preflight"
    mkdir -p "$probe"
    printf 'let preflight = 1\n' > "$probe/Preflight.swift"

    # `out=$(cmd); status=$?` is wrong under `set -e`: the failing assignment
    # aborts the script before $? is ever read, so the diagnostic below never
    # prints. Assigning inside an `if` condition suppresses errexit correctly.
    local out status=0
    if [ "$TOOLCHAIN" = "docker" ]; then
        if ! out="$(docker run --rm \
            --user "$(id -u):$(id -g)" \
            -e HOME=/tmp \
            -v "$probe":/p \
            "${FREESNITCH_SWIFT_IMAGE:-swift:6.0-noble}" \
            bash -c "swiftc -typecheck /p/Preflight.swift" 2>&1)"; then
            status=1
        fi
    else
        if ! out="$(swiftc -typecheck "$probe/Preflight.swift" 2>&1)"; then
            status=1
        fi
    fi

    rm -rf "$probe"

    if [ "$status" -ne 0 ]; then
        fail "toolchain cannot compile a trivial file, so its silence proves nothing.
  toolchain: $TOOLCHAIN
  image:     ${FREESNITCH_SWIFT_IMAGE:-swift:6.0-noble}
  output:    $out"
    fi
}

# Extract the first file (by path order) that has a type-check error.
# Returns basename only for clarity in reports.
first_error_file() {
    local output="$1"

    # Lines like "w/AppBundleIdentity.swift:1: error:"
    # We want just the filename from the first error.
    local path
    path="$(echo "$output" | grep "error:" | grep -v "^ *|" | sed -E 's|^([^:]+):.*|\1|' | sort -u | head -1 || true)"

    if [ -n "$path" ]; then
        basename "$path"
    fi
}

# Count distinct error messages in output for a given file.
error_count_for_file() {
    local file_path="$1"
    local output="$2"

    echo "$output" | grep "error:" | grep "$(basename "$file_path")" | wc -l || true
}

# Extract distinct missing symbols from error output.
# Looks for patterns like "cannot find 'X' in scope" or "no such module 'X'".
extract_symbols() {
    local output="$1"

    # Extract module names: "no such module 'Darwin'" → "Darwin"
    echo "$output" | grep -o "no such module '[^']*'" | sed "s/no such module '//" | sed "s/'$//" || true

    # Extract symbol names: "cannot find 'DistributedNotificationCenter'" → "DistributedNotificationCenter"
    echo "$output" | grep -o "cannot find '[^']*'" | sed "s/cannot find '//" | sed "s/'$//" || true

    # Extract type names: "cannot find type 'NSXPCInterface'" → "NSXPCInterface"
    echo "$output" | grep -o "cannot find type '[^']*'" | sed "s/cannot find type '//" | sed "s/'$//" || true
}

# Check if a symbol is declared in real Sources/Shared.
symbol_exists_in_shared() {
    local sym="$1"

    grep -r "\\b\\(struct\\|class\\|enum\\|protocol\\|typealias\\|actor\\)\\s\\+$sym\\b" \
        "$ROOT/Sources/Shared" >/dev/null 2>&1
}

# Classify a failure: real blocker or cascade.
classify_failure() {
    local file="$1"
    local symbols="$2"

    # If any symbol is a missing module, it's always a real blocker.
    if echo "$symbols" | grep -E "^(Darwin|Compression|os.log|SQLite3|Security|NSXPC|DistributedNotificationCenter)$" >/dev/null 2>&1 || [ -z "$symbols" ]; then
        printf 'real'
        return 0
    fi

    # Check if all symbols are declared in Sources/Shared.
    local all_declared=true
    while IFS= read -r sym; do
        [ -z "$sym" ] && continue
        if ! symbol_exists_in_shared "$sym"; then
            all_declared=false
            break
        fi
    done < <(echo "$symbols" | sort -u)

    if [ "$all_declared" = true ]; then
        printf 'cascade'
    else
        printf 'real'
    fi
}

main() {
    # Copy sources to work directory
    copy_sources_to_work() {
        find "$ROOT/Sources/Shared" -name '*.swift' -exec cp {} "$WORK/" \;
    }

    copy_sources_to_work

    # Must run before the sweep: a toolchain that cannot start produces no
    # errors, and no errors reads as a clean portable core.
    preflight_toolchain

    # Track which files fail and how, in order. Initialised empty so that an
    # early exit reports "nothing was classified" rather than tripping over an
    # unbound variable, which would mask the real failure.
    local -a FAILED_FILES=()
    local -a FAILED_CLASSIFICATIONS=()
    local -a FAILED_SYMBOLS=()
    local -a FAILED_COUNTS=()

    local MAX_ROUNDS=20
    local ROUND=0

    while [ "$ROUND" -lt "$MAX_ROUNDS" ]; do
        ROUND=$((ROUND + 1))

        # List files and compile.
        local -a files
        mapfile -t files < <(find "$WORK" -name '*.swift' | sort)

        if [ "${#files[@]}" -eq 0 ]; then
            break
        fi

        local output
        output="$(compile "${files[@]}")"

        # Check if clean.
        if ! echo "$output" | grep -q "error:" 2>/dev/null || [ -z "$output" ]; then
            break
        fi

        # Find the first erroring file.
        local bad_file
        bad_file="$(first_error_file "$output")"

        if [ -z "$bad_file" ]; then
            # Shouldn't happen, but bail if we can't parse the error.
            fail "could not parse error output: $output"
        fi

        # Record this failure.
        local bad_path="$WORK/$bad_file"
        local error_count
        error_count="$(error_count_for_file "$bad_file" "$output")"
        local symbols
        symbols="$(extract_symbols "$output" | sort -u)"

        FAILED_FILES+=("$bad_file")
        FAILED_COUNTS+=("$error_count")
        FAILED_SYMBOLS+=("$symbols")

        # Classify it.
        local classification
        classification="$(classify_failure "$bad_file" "$symbols")"
        FAILED_CLASSIFICATIONS+=("$classification")

        # Remove the file and loop.
        rm -f "$bad_path"
    done

    # Count what's left and what failed.
    local -a remaining_files
    mapfile -t remaining_files < <(find "$WORK" -name '*.swift' | sort)
    local remaining_count="${#remaining_files[@]}"

    # Prepare report.
    {
        printf 'portable core check: %d files compile clean on Linux\n' "$remaining_count"
        printf '\n'

        if [ "${#FAILED_FILES[@]}" -gt 0 ]; then
            printf 'Files with blocker dependencies:\n'
            local i
            for ((i = 0; i < ${#FAILED_FILES[@]}; i++)); do
                local file="${FAILED_FILES[$i]}"
                local class="${FAILED_CLASSIFICATIONS[$i]}"
                local count="${FAILED_COUNTS[$i]}"
                local symbols="${FAILED_SYMBOLS[$i]}"
                printf '  %s (%s): %d errors\n' "$file" "$class" "$count"
                if [ -n "$symbols" ]; then
                    printf '    Symbols: %s\n' "$symbols"
                fi
            done
            printf '\n'
        fi
    } | tee /tmp/portable_report.txt

    # Check for regressions: real blockers not in the expected list.
    local REGRESSION=false
    for ((i = 0; i < ${#FAILED_FILES[@]}; i++)); do
        local file="${FAILED_FILES[$i]}"
        local class="${FAILED_CLASSIFICATIONS[$i]}"

        if [ "$class" = "real" ]; then
            local is_expected=false
            for expected in "${EXPECTED_BLOCKERS[@]}"; do
                if [ "$file" = "$expected" ]; then
                    is_expected=true
                    break
                fi
            done

            if [ "$is_expected" = false ]; then
                printf 'FAIL: unexpected blocker %s (portability regressed)\n' "$file" >&2
                REGRESSION=true
            fi
        fi
    done

    # Check for progress: expected blockers now clean.
    for expected in "${EXPECTED_BLOCKERS[@]}"; do
        local found_in_failures=false
        for ((i = 0; i < ${#FAILED_FILES[@]}; i++)); do
            if [ "${FAILED_FILES[$i]}" = "$expected" ]; then
                found_in_failures=true
                break
            fi
        done

        if [ "$found_in_failures" = false ]; then
            # This file compiles clean now — report as progress.
            printf 'portable core check: %s now compiles clean (progress!)\n' "$expected"
        fi
    done

    if [ "$REGRESSION" = true ]; then
        printf 'portable core check: FAIL\n' >&2
        return 1
    fi

    printf 'portable core check: PASS\n'
    return 0
}

main "$@"
