import Foundation

/// PlatformEnvironment provides a seam for platform-specific configuration:
/// filesystem paths (data, config, state), executable location, version, and
/// bundle identity. This abstraction enables byte-identical behavior on macOS
/// while respecting XDG Base Directory spec on Linux and Windows conventions
/// on Windows.
///
/// The seam is implemented by platform-specific backends that are compiled
/// conditionally: PlatformEnvironmentMacOS on Apple, PlatformEnvironmentLinux
/// on Linux, etc. Callers use the static `dataDir`, `configDir`, `stateDir`,
/// `executablePath`, `runtimeVersion`, and `bundleIdentifier` properties.

// MARK: - Static Properties (entry points)

public enum PlatformEnvironment {
    /// The directory for persistent application state (e.g., rule database,
    /// preferences). This directory persists across reboots.
    ///
    /// - macOS: `~/Library/Application Support/FreeSnitch`
    /// - Linux: `$XDG_DATA_HOME/FreeSnitch` or `~/.local/share/FreeSnitch`
    /// - Windows: `%APPDATA%\FreeSnitch`
    ///
    /// The directory is created on access if it does not exist.
    public static var dataDir: URL {
        getPlatformBackend().dataDir
    }

    /// The directory for application configuration files.
    ///
    /// - macOS: `~/Library/Application Support/FreeSnitch` (shared with dataDir)
    /// - Linux: `$XDG_CONFIG_HOME/FreeSnitch` or `~/.config/FreeSnitch`
    /// - Windows: `%APPDATA%\FreeSnitch` (shared with dataDir)
    ///
    /// The directory is created on access if it does not exist.
    public static var configDir: URL {
        getPlatformBackend().configDir
    }

    /// The directory for runtime/temporary state (e.g., the Unix socket path).
    /// On systems with a tmpfs mount, this directory is typically cleared on reboot.
    ///
    /// - macOS: Same as dataDir (no tmpfs equivalent; persists across reboots)
    /// - Linux: `$XDG_RUNTIME_DIR/freesnitch` or `/run/freesnitch` for system daemons
    /// - Windows: `%TEMP%\FreeSnitch`
    ///
    /// NOTE: The directory is NOT assumed to persist. The caller must create
    /// it if missing before using it for the socket or other runtime files.
    /// On Linux, this is critical: XDG_RUNTIME_DIR and /run are tmpfs and cleared
    /// on reboot.
    public static var stateDir: URL {
        getPlatformBackend().stateDir
    }

    /// The full path to the running executable.
    public static var executablePath: URL {
        getPlatformBackend().executablePath
    }

    /// The bundle or application identifier. On macOS, this is the bundle
    /// identifier from the Info.plist (e.g., "io.isaaclins.freesnitch").
    /// On Linux and Windows, it is a default identifier.
    public static var bundleIdentifier: String {
        getPlatformBackend().bundleIdentifier
    }

    /// The runtime version string (e.g., "0.2.0"), if available.
    /// - macOS: Read from the Info.plist of the running bundle.
    /// - Linux: Throws PlatformEnvironmentError.versionUnavailable because
    ///   `Bundle.main` has no Info.plist.
    /// - Windows: May read from assembly metadata or throw.
    ///
    /// This method never returns a fabricated default. If the version is
    /// not determinable, it throws.
    public static func runtimeVersion() throws -> String {
        try getPlatformBackend().runtimeVersion()
    }

    /// Whether the running process is the installed version (macOS-specific).
    /// On macOS, this detects whether the running process is the version
    /// installed on disk (via Info.plist comparison). On non-Apple platforms,
    /// this property is meaningless and should not be accessed.
    ///
    /// Required by R5.5 for the test_helper_identity.sh harness.
    #if os(macOS)
    public static var isRunningInstance: Bool {
        (getPlatformBackend() as? PlatformEnvironmentMacOS)?.isRunningInstance ?? false
    }
    #endif

    // MARK: - Private: Backend Selection

    private static var _backend: PlatformEnvironmentBackend?

    private static func getPlatformBackend() -> PlatformEnvironmentBackend {
        if let existing = _backend {
            return existing
        }
        let backend: PlatformEnvironmentBackend
        #if os(macOS)
        backend = PlatformEnvironmentMacOS()
        #elseif os(Linux)
        backend = PlatformEnvironmentLinux()
        #elseif os(Windows)
        backend = PlatformEnvironmentWindows()
        #else
        // Fallback for unknown platforms
        backend = PlatformEnvironmentGeneric()
        #endif
        _backend = backend
        return backend
    }
}

// MARK: - Backend Protocol (internal)

protocol PlatformEnvironmentBackend {
    var dataDir: URL { get }
    var configDir: URL { get }
    var stateDir: URL { get }
    var executablePath: URL { get }
    var bundleIdentifier: String { get }
    func runtimeVersion() throws -> String
}

// MARK: - Errors

public enum PlatformEnvironmentError: Error {
    /// Version information is not available on this platform.
    case versionUnavailable
}
