#if os(Windows) || !(os(macOS) || os(Linux))
import Foundation

/// Generic/Windows implementation of PlatformEnvironment.
/// Serves as a fallback for platforms without dedicated implementations.
/// On Windows, paths use %APPDATA% for data/config and %TEMP% for runtime files.
class PlatformEnvironmentGeneric: PlatformEnvironmentBackend {
    private let fm = FileManager.default
    private let env = ProcessInfo.processInfo.environment

    var dataDir: URL {
        let basePath: String
        #if os(Windows)
        if let appData = env["APPDATA"] {
            basePath = appData
        } else {
            basePath = NSHomeDirectory() + "\\AppData\\Roaming"
        }
        #else
        basePath = NSHomeDirectory() + "/.local/share"
        #endif
        let dir = URL(fileURLWithPath: basePath + "/FreeSnitch", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var configDir: URL {
        // On Windows, config and data are the same.
        return dataDir
    }

    var stateDir: URL {
        let basePath: String
        #if os(Windows)
        if let temp = env["TEMP"] {
            basePath = temp
        } else {
            basePath = NSHomeDirectory() + "\\AppData\\Local\\Temp"
        }
        #else
        basePath = NSHomeDirectory() + "/.local/state"
        #endif
        let dir = URL(fileURLWithPath: basePath + "/FreeSnitch", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var executablePath: URL {
        URL(fileURLWithPath: CommandLine.arguments[0])
    }

    var bundleIdentifier: String {
        "io.isaaclins.freesnitch"
    }

    func runtimeVersion() throws -> String {
        throw PlatformEnvironmentError.versionUnavailable
    }
}
#endif
