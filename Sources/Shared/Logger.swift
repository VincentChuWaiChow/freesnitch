import Foundation

#if canImport(os)
import os.log
#endif

public enum PSLog {
#if canImport(os)
    public typealias Category = OSLog

    private static func make(_ name: String) -> Category {
        OSLog(subsystem: AppConstants.bundleIdGUI, category: name)
    }
#else
    /// os.log has no counterpart in swift-corelibs-foundation, so off-Apple the
    /// category is just its name and the backend writes to stderr. Keeping the
    /// type behind PSLog means the 84 call sites never learn which backend ran.
    public struct Category: Sendable {
        public let name: String
    }

    private static func make(_ name: String) -> Category {
        Category(name: name)
    }
#endif

    public static let app = make("app")
    public static let helper = make("helper")
    public static let dns = make("dns")
    public static let pf = make("pf")
    public static let netmon = make("netmon")
    public static let netext = make("netext")

#if canImport(os)
    public static func info(_ log: Category, _ msg: String) {
        os_log("%{public}@", log: log, type: .info, msg)
    }

    public static func error(_ log: Category, _ msg: String) {
        os_log("%{public}@", log: log, type: .error, msg)
    }

    public static func debug(_ log: Category, _ msg: String) {
        os_log("%{public}@", log: log, type: .debug, msg)
    }
#else
    public static func info(_ log: Category, _ msg: String) {
        fputs("[\(log.name)] [info] \(msg)\n", stderr)
    }

    public static func error(_ log: Category, _ msg: String) {
        fputs("[\(log.name)] [error] \(msg)\n", stderr)
    }

    public static func debug(_ log: Category, _ msg: String) {
        fputs("[\(log.name)] [debug] \(msg)\n", stderr)
    }
#endif
}
