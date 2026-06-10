import Foundation
import SwiftUI

/// Main engine that orchestrates the full BookRestore pipeline.
///
/// The restore operation uses a pluggable strategy pattern — three implementations
/// of the mobilebackup2 protocol are available:
///
///   1. **libimobiledevice** (`.libIMD`) — Uses the C library directly.
///      Fastest and most reliable. Requires linking libimobiledevice.
///      Best for: macOS builds where you control the environment.
///
///   2. **Pure Swift** (`.pureSwift`) — Native Swift DLMessage protocol implementation.
///      No external dependencies. Connects directly to minimuxer tunnel.
///      Best for: On-device (iOS) builds and when you can't link C libraries.
///
///   3. **Python Bridge** (`.pythonBridge`) — Shells out to pymobiledevice3.
///      Same library Nugget uses. Requires Python 3 installed.
///      Best for: Development, quick testing, when other options aren't available.
///
/// Strategy selection is persisted in `@AppStorage` and can be changed in the UI.
@MainActor
class BookRestoreEngine: ObservableObject {

    // MARK: - State

    enum Status: Equatable {
        case idle
        case building
        case restoring(String)  // associated value = strategy display name
        case success
        case failed(String)

        static func == (lhs: Status, rhs: Status) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle),
                 (.building, .building),
                 (.success, .success): return true
            case (.restoring(let a), .restoring(let b)): return a == b
            case (.failed(let a), .failed(let b)): return a == b
            default: return false
            }
        }
    }

    @Published var status: Status = .idle
    @Published var progress: Double = 0.0

    /// The currently selected restore strategy. Persisted across app launches.
    @AppStorage("restoreStrategy") var selectedStrategy: RestoreStrategy = .pureSwift

    /// Whether a restore operation is currently in progress.
    var isRunning: Bool {
        switch status {
        case .building, .restoring: return true
        default: return false
        }
    }

    // MARK: - Public API

    /// Apply the given Siri waitlist state via BookRestore using the selected strategy.
    func apply(state: PlistPayloadBuilder.SiriWaitlistState) async {
        status = .building
        setProgress(0.1)

        do {
            // Step 1: Ensure pairing file exists
            guard let pairingPath = PairingFileManager.shared.pairingFilePath else {
                throw EngineError.noPairingFile
            }
            setProgress(0.15)

            // Step 2: Start minimuxer tunnel
            try MinimuxerBridge.shared.start(pairingFilePath: pairingPath)
            setProgress(0.25)

            // Step 3: Build plist payload
            let plistData = PlistPayloadBuilder.build(state: state)
            setProgress(0.35)

            // Step 4: Wrap in BackupFile
            let backupFile = BackupFile(
                domain: "RootDomain",
                relativePath: "Library/FeatureFlags/Domain/GenerativeModels.plist",
                data: plistData
            )
            setProgress(0.45)

            // Step 5: Build backup directory
            let backupDir = try BackupManifestBuilder.buildBackup(files: [backupFile])
            setProgress(0.55)

            // Step 6: Execute restore using selected strategy
            let strategy = selectedStrategy
            status = .restoring(strategy.displayName)
            setProgress(0.60)

            // Try primary strategy first, fall back to others on failure
            try await executeWithFallback(
                primary: strategy,
                backupDir: backupDir,
                progress: { [weak self] p in
                    guard let self else { return }
                    self.setProgress(p)
                }
            )

            // Step 7: Cleanup
            try? FileManager.default.removeItem(at: backupDir)
            setProgress(1.0)

            status = .success

        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// Convenience for setting an error from outside (e.g. file import failure).
    func setError(_ message: String) {
        status = .failed(message)
    }

    /// Reset state (for retry).
    func reset() {
        status = .idle
        progress = 0.0
    }

    // MARK: - Strategy Execution

    /// Execute the primary strategy, falling back to others if it fails.
    ///
    /// Fallback order:
    ///   1. Try user-selected strategy
    ///   2. If libIMD fails → try pureSwift
    ///   3. If pureSwift fails → try pythonBridge (if on macOS)
    private func executeWithFallback(
        primary: RestoreStrategy,
        backupDir: URL,
        progress: @escaping (Double) -> Void
    ) async throws {
        let strategies = orderedStrategies(startingWith: primary)

        var lastError: Error?
        for strategy in strategies {
            do {
                let impl = strategy.makeStrategy()
                try await impl.restore(backupDir: backupDir, progress: progress)
                return  // Success
            } catch {
                lastError = error
                // Don't fallback for certain fatal errors
                if let restoreError = error as? RestoreError {
                    switch restoreError {
                    case .backupDirNotFound,
                         .timeout:
                        continue  // Try next strategy
                    case .libIMDNotLinked,
                         .pythonNotFound,
                         .notAvailable:
                        continue  // Strategy not available, try next
                    case .connectionFailed,
                         .versionExchangeFailed,
                         .restoreRequestRejected,
                         .fileTransferFailed,
                         .unexpectedMessage,
                         .pythonScriptFailed:
                        throw error  // These are actual failures, don't silently fallback
                    }
                }
            }
        }

        // All strategies exhausted
        if let lastError = lastError {
            throw lastError
        } else {
            throw RestoreError.notAvailable("No restore strategy is available.")
        }
    }

    /// Determine the strategy order, putting the preferred strategy first.
    private func orderedStrategies(startingWith preferred: RestoreStrategy) -> [RestoreStrategy] {
        var ordered: [RestoreStrategy] = [preferred]
        for s in RestoreStrategy.allCases where s != preferred {
            ordered.append(s)
        }
        return ordered
    }

    // MARK: - Helpers

    private func setProgress(_ value: Double) {
        progress = value
    }
}

// MARK: - Engine Errors

enum EngineError: Error, LocalizedError {
    case noPairingFile
    case minimuxerFailed
    case noStrategyAvailable

    var errorDescription: String? {
        switch self {
        case .noPairingFile:
            return "No pairing file found. Import your .mobiledevicepairing file first."
        case .minimuxerFailed:
            return "minimuxer failed to start. Check Developer Mode is enabled."
        case .noStrategyAvailable:
            return "No restore strategy is available. Install pymobiledevice3 or link libimobiledevice."
        }
    }
}
