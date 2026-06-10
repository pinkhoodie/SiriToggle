import Foundation

// MARK: - Strategy Protocol

/// Common interface for all mobilebackup2 restore implementations.
protocol RestoreStrategyProtocol: Sendable {
    /// Human-readable name for UI display.
    static var displayName: String { get }
    /// Detailed description for the info sheet.
    static var description: String { get }
    /// Whether this strategy requires libimobiledevice to be linked.
    static var requiresLibIMD: Bool { get }
    /// Whether this strategy requires Python to be installed.
    static var requiresPython: Bool { get }
    /// Whether this strategy works on-device (iOS) without a Mac.
    static var worksOnDevice: Bool { get }

    /// Execute the restore using the given backup directory.
    /// - Parameters:
    ///   - backupDir: URL to the prepared backup directory.
    ///   - progress: Callback for progress updates (0.0...1.0).
    /// - Throws: RestoreError on failure.
    func restore(backupDir: URL, progress: @escaping (Double) -> Void) async throws
}

// MARK: - Strategy Enum

/// The three available restore strategies. Each maps to a different implementation
/// of the mobilebackup2 protocol. Users can select which one to use.
enum RestoreStrategy: String, CaseIterable, Identifiable, Sendable {
    case libIMD       = "libimobiledevice"
    case pureSwift    = "pure-swift"
    case pythonBridge = "python-bridge"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .libIMD:       return "libimobiledevice"
        case .pureSwift:    return "Pure Swift"
        case .pythonBridge: return "Python Bridge"
        }
    }

    var description: String {
        switch self {
        case .libIMD:
            return "Uses the libimobiledevice C library. Fastest and most reliable, but requires linking the static library. Best for macOS builds."
        case .pureSwift:
            return "Native Swift implementation of the mobilebackup2 protocol. No external dependencies. Best for on-device (iOS) builds."
        case .pythonBridge:
            return "Shells out to pymobiledevice3. Requires Python to be installed. Good fallback for development."
        }
    }

    var icon: String {
        switch self {
        case .libIMD:       return "c.circle.fill"
        case .pureSwift:    return "swift"
        case .pythonBridge: return "terminal.fill"
        }
    }

    var color: String {
        switch self {
        case .libIMD:       return "blue"
        case .pureSwift:    return "orange"
        case .pythonBridge: return "green"
        }
    }

    /// Instantiate the concrete strategy implementation.
    func makeStrategy() -> any RestoreStrategyProtocol {
        switch self {
        case .libIMD:       return LibIMDRestoreStrategy()
        case .pureSwift:    return PureSwiftRestoreStrategy()
        case .pythonBridge: return PythonBridgeRestoreStrategy()
        }
    }
}

// MARK: - Common Errors

enum RestoreError: Error, LocalizedError, Sendable {
    case connectionFailed(String)
    case versionExchangeFailed
    case restoreRequestRejected(String)
    case fileTransferFailed(String)
    case unexpectedMessage(String)
    case timeout
    case notAvailable(String)
    case libIMDNotLinked
    case pythonNotFound
    case pythonScriptFailed(String)
    case backupDirNotFound

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let msg):
            return "Connection failed: \(msg)"
        case .versionExchangeFailed:
            return "MobileBackup2 version exchange failed. Incompatible protocol."
        case .restoreRequestRejected(let msg):
            return "Restore request rejected: \(msg)"
        case .fileTransferFailed(let msg):
            return "File transfer failed: \(msg)"
        case .unexpectedMessage(let msg):
            return "Unexpected message: \(msg)"
        case .timeout:
            return "Operation timed out. Check device connection."
        case .notAvailable(let msg):
            return "Strategy not available: \(msg)"
        case .libIMDNotLinked:
            return "libimobiledevice is not linked. Build with the libimobiledevice XCFramework or select a different strategy."
        case .pythonNotFound:
            return "Python 3 is not installed or not in PATH. Install Python or select a different strategy."
        case .pythonScriptFailed(let msg):
            return "Python script failed: \(msg)"
        case .backupDirNotFound:
            return "Backup directory not found. Build the backup first."
        }
    }
}
