import Foundation

#if canImport(Glibc)
import Glibc

// MARK: - Kernel ABI

/// Kernel `struct ucred`. Declared here because glibc guards it behind
/// _GNU_SOURCE, which Swift's Glibc modulemap does not define. This is stable
/// kernel ABI (three 32-bit fields), not a libc detail, so declaring it is safe
/// and keeps us free of a C shim target. Layout is: pid, uid, gid (all 32-bit).
@frozen
public struct FSPeerCred: Sendable {
    public var pid: pid_t = 0
    public var uid: uid_t = 0
    public var gid: gid_t = 0
}

// MARK: - SO_PEERCRED architecture mapping

/// Numeric value of SO_PEERCRED for the current architecture. Linux kernel ABI.
/// Verified on x86_64/aarch64. Other architectures use different values.
/// Per R4.5, architectures not recognized here are refused (fail-closed).
private func so_peercred() -> Int32? {
    #if arch(x86_64) || arch(arm64) || arch(i386)
    // x86_64, aarch64, i386
    return 17
    #elseif arch(powerpc64)
    // powerpc64
    return 21
    #else
    // Unknown or unsupported architecture: refuse per R4.5
    return nil
    #endif
}

// MARK: - Linux peer authenticator

/// Authenticates peers connecting to a Unix domain socket using SO_PEERCRED.
///
/// This implementation follows policy **L1** from the design:
/// - Authorizes on uid/gid only, never on pid
/// - Operates on a filesystem-bound socket in a 0700 root-owned directory
/// - Refuses any peer whose credentials cannot be established
/// - Logs refusals without disclosing the reason to the peer (R4.6)
///
/// **PID handling:** The kernel reports the peer's PID at connect time, which
/// is captured in the credentials struct. However, PID is subject to reuse:
/// by the time a decision is made, the PID may belong to a different process.
/// See L3 rejection in 05-peer-authentication.md. **PID is logged for diagnostics
/// only and must not influence authorization.**
public final class LinuxPeerAuthenticator: @unchecked Sendable {
    /// Expected UID of the peer, or nil to skip UID check.
    private let expectedUID: uid_t?
    /// Expected GID of the peer, or nil to skip GID check.
    private let expectedGID: gid_t?

    /// Create an authenticator for peers connecting to a privileged service.
    ///
    /// At least one of expectedUID or expectedGID must be supplied; if both are
    /// nil, all peers are refused.
    ///
    /// - Parameters:
    ///   - expectedUID: UID the peer must have, or nil to skip UID check.
    ///   - expectedGID: GID the peer must have, or nil to skip GID check.
    public init(expectedUID: uid_t? = nil, expectedGID: gid_t? = nil) {
        self.expectedUID = expectedUID
        self.expectedGID = expectedGID
    }

    /// Authenticate the peer on a connected Unix domain socket descriptor.
    ///
    /// Reads the peer credentials via getsockopt(SO_PEERCRED). Authorization
    /// succeeds only if:
    /// - At least one expected credential (uid or gid) was supplied at construction.
    /// - All supplied expected credentials match the peer's credentials.
    /// - The descriptor is valid and connected.
    ///
    /// On failure, logs the reason for diagnostics (not disclosed to the peer,
    /// per R4.6) and returns false.
    ///
    /// - Parameter fd: A connected Unix domain socket descriptor.
    /// - Returns: true if and only if the peer is authorized.
    public func authenticate(fd: Int32) -> Bool {
        // Refuse if no credentials were specified at construction
        guard expectedUID != nil || expectedGID != nil else {
            PSLog.error(PSLog.helper, "peer auth: refused - no credentials configured")
            return false
        }

        // Refuse if SO_PEERCRED is not available on this architecture
        guard let soPerecred = so_peercred() else {
            PSLog.error(PSLog.helper, "peer auth: refused - SO_PEERCRED not defined for this architecture")
            return false
        }

        // Read peer credentials
        var cred = FSPeerCred()
        var len = socklen_t(MemoryLayout<FSPeerCred>.size)
        let rc = withUnsafeMutablePointer(to: &cred) { p in
            getsockopt(fd, SOL_SOCKET, soPerecred, UnsafeMutableRawPointer(p), &len)
        }

        // Refuse if getsockopt failed
        guard rc == 0 else {
            PSLog.error(PSLog.helper, "peer auth: refused - could not read socket credentials")
            return false
        }

        // Log the peer for diagnostics (pid is not used for authorization)
        PSLog.debug(PSLog.helper, "peer auth: read credentials - pid=\(cred.pid) uid=\(cred.uid) gid=\(cred.gid)")

        // Check UID if configured
        if let expectedUID = expectedUID {
            guard cred.uid == expectedUID else {
                PSLog.error(PSLog.helper, "peer auth: refused - uid mismatch")
                return false
            }
        }

        // Check GID if configured
        if let expectedGID = expectedGID {
            guard cred.gid == expectedGID else {
                PSLog.error(PSLog.helper, "peer auth: refused - gid mismatch")
                return false
            }
        }

        // All checks passed
        PSLog.debug(PSLog.helper, "peer auth: authorized")
        return true
    }
}

#endif
