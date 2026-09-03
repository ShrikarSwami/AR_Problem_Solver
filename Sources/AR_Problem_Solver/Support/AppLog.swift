import Foundation
import os

/// Thin wrapper over `os.Logger` so call sites read `AppLog.solver.info(...)`.
enum AppLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.shrikar.AR-Problem-Solver"

    static let wearables = Logger(subsystem: subsystem, category: "wearables")
    static let camera = Logger(subsystem: subsystem, category: "camera")
    static let display = Logger(subsystem: subsystem, category: "display")
    static let claude = Logger(subsystem: subsystem, category: "claude")
    static let solver = Logger(subsystem: subsystem, category: "solver")
}
