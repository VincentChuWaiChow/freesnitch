#if os(Linux)
import Foundation

/// Linux implementation of PlatformEnvironment.
/// Follows the XDG Base Directory specification for locating configuration,
/// data, and runtime files. On Linux, stateDir (runtime files) uses tmpfs
/// and MUST be created at startup because it is cleared on reboot.
class PlatformEnvironmentLinux: PlatformEnvironmentBackend {
    private let fm = FileManager.default
    private let env = ProcessInfo.processInfo.environment

    var dataDir: URL {
        let basePath: String
        if let xdgDataHome = env["XDG_DATA_HOME"], !xdgDataHome.isEmpty {
            basePath = xdgDataHome
        } else {
            let home = NSHomeDirectory()
            basePath = home + "/.local/share"
        }
        let dir = URL(fileURLWithPath: basePath + "/FreeSnitch", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var configDir: URL {
        let basePath: String
        if let xdgConfigHome = env["XDG_CONFIG_HOME"], !xdgConfigHome.isEmpty {
            basePath = xdgConfigHome
        } else {
            let home = NSHomeDirectory()
            basePath = home + "/.config"
        }
        let dir = URL(fileURLWithPath: basePath + "/FreeSnitch", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var stateDir: URL {
        let basePath: String
        if let xdgRuntimeDir = env["XDG_RUNTIME_DIR"], !xdgRuntimeDir.isEmpty {
            basePath = xdgRuntimeDir + "/freesnitch"
        } else {
            basePath = "/run/freesnitch"
        }
        let dir = URL(fileURLWithPath: basePath, isDirectory: true)
        // NOTE: We do NOT automatically create stateDir here, as tmpfs is cleared on reboot.
        // The caller must create it at startup if needed. This is critical for the socket path.
        return dir
    }

    var executablePath: URL {
        URL(fileURLWithPath: CommandLine.arguments[0])
    }

    var bundleIdentifier: String {
        "io.isaaclins.freesnitch"
    }

    func runtimeVersion() throws -> String {
        // On Linux, Bundle.main has no Info.plist (Linux Foundation limitation).
        // Never return a fabricated default; throw instead.
        throw PlatformEnvironmentError.versionUnavailable
    }
}
#endif
