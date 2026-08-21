#if os(macOS)
import Foundation

/// macOS implementation of PlatformEnvironment.
/// Preserves byte-for-byte compatibility with the current AppConstants.supportDir.
class PlatformEnvironmentMacOS: PlatformEnvironmentBackend {
    private let fm = FileManager.default
    private let inMemoryInfo: [String: Any]
    private let onDiskInfo: [String: Any]?

    var dataDir: URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("FreeSnitch", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var configDir: URL {
        // On macOS, config and data are the same location.
        return dataDir
    }

    var stateDir: URL {
        // On macOS, state and data are the same location (no tmpfs equivalent).
        return dataDir
    }

    var executablePath: URL {
        URL(fileURLWithPath: CommandLine.arguments[0])
    }

    var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "io.isaaclins.freesnitch"
    }

    func runtimeVersion() throws -> String {
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            return version
        }
        throw PlatformEnvironmentError.versionUnavailable
    }

    /// Whether the running process is the installed version on disk.
    /// This detects when Info.plist has been rewritten (e.g., by an in-place update)
    /// and the running process still has the old in-memory Info dictionary.
    ///
    /// Required for test_helper_identity.sh, which rewrites Info.plist on disk
    /// and expects the running process to detect the change on the next identity check.
    var isRunningInstance: Bool {
        guard let inMemory = inMemoryInfo as? [String: String],
              let onDisk = onDiskInfo as? [String: String] else {
            return true // Default to yes if we can't compare
        }

        let inMemoryVersion = inMemory["CFBundleShortVersionString"]
        let onDiskVersion = onDisk["CFBundleShortVersionString"]
        let inMemoryBuild = inMemory["CFBundleVersion"]
        let onDiskBuild = onDisk["CFBundleVersion"]

        return inMemoryVersion == onDiskVersion && inMemoryBuild == onDiskBuild
    }

    init() {
        // Capture the in-memory Info dictionary from the running bundle.
        self.inMemoryInfo = Bundle.main.infoDictionary ?? [:]

        // Try to read the on-disk Info.plist from the bundle.
        if let bundlePath = Bundle.main.bundlePath,
           let infoPlistPath = fm.fileExists(atPath: bundlePath + "/Contents/Info.plist")
               ? bundlePath + "/Contents/Info.plist"
               : (fm.fileExists(atPath: bundlePath + "/Info.plist") ? bundlePath + "/Info.plist" : nil),
           let onDiskDict = NSDictionary(contentsOfFile: infoPlistPath) as? [String: Any] {
            self.onDiskInfo = onDiskDict
        } else {
            self.onDiskInfo = nil
        }
    }
}
#endif
