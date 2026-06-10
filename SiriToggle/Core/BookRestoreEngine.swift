import Foundation

/// Main engine that orchestrates the full BookRestore pipeline:
///   1. Start minimuxer tunnel
///   2. Build plist payload
///   3. Build backup directory structure
///   4. Trigger mobilebackup2 restore
///   5. Clean up temp files
///
/// This is the equivalent of Nugget's BookRestoreManager.swift.
/// Reference for the mobilebackup2 client implementation:
///   https://github.com/leminlimez/Nugget/blob/main/Nugget/Controllers/Tweaks/BookRestoreManager.swift
@MainActor
class BookRestoreEngine: ObservableObject {

    // MARK: - State

    enum Status: Equatable {
        case idle
        case building
        case restoring
        case success
        case failed(String)

        static func == (lhs: Status, rhs: Status) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.building, .building),
                 (.restoring, .restoring), (.success, .success): return true
            case (.failed(let a), .failed(let b)): return a == b
            default: return false
            }
        }
    }

    @Published var status: Status = .idle
    @Published var progress: Double = 0.0

    // MARK: - Public API

    /// Apply the given Siri waitlist state via BookRestore.
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
            // Domain: RootDomain maps to / (root filesystem)
            // relativePath: Library/FeatureFlags/Domain/GenerativeModels.plist
            // → resolves to /System/Library/FeatureFlags/Domain/GenerativeModels.plist
            //
            // NOTE: On some iOS versions SysContainerDomain- may be needed instead.
            // If RootDomain fails, try: domain = "SysContainerDomain-"
            let backupFile = BackupFile(
                domain: "RootDomain",
                relativePath: "Library/FeatureFlags/Domain/GenerativeModels.plist",
                data: plistData
            )
            setProgress(0.45)

            // Step 5: Build backup directory
            let backupDir = try BackupManifestBuilder.buildBackup(files: [backupFile])
            setProgress(0.55)

            // Step 6: Trigger mobilebackup2 restore
            status = .restoring
            setProgress(0.6)
            try await triggerBookRestore(backupDir: backupDir)
            setProgress(0.95)

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

    // MARK: - mobilebackup2 Restore

    /// Triggers the BookRestore via the com.apple.mobilebackup2 service.
    ///
    /// ════════════════════════════════════════════════════════
    ///  IMPLEMENTATION NOTE — READ BEFORE BUILDING
    /// ════════════════════════════════════════════════════════
    ///
    /// This function needs a full mobilebackup2 protocol client in Swift.
    /// The protocol runs over the minimuxer tunnel (localhost:27015).
    ///
    /// The authoritative Swift implementation already exists in Nugget:
    ///   https://github.com/leminlimez/Nugget
    ///   File: Nugget/Controllers/Tweaks/BookRestoreManager.swift
    ///
    /// Copy that implementation here. The key steps are:
    ///
    ///   1. Connect to minimuxer at localhost:27015
    ///   2. Start lockdown session (AMDeviceConnect / AMDeviceStartSession)
    ///   3. Start mobilebackup2 service
    ///   4. Send DLMessageVersionExchange (version negotiation)
    ///   5. Send RestoreBackup message with these options:
    ///        {
    ///          "RestoreSystemFiles":        true,   ← CRITICAL: enables RootDomain writes
    ///          "RemoveItemsNotRestored":    false,  ← CRITICAL: don't wipe device
    ///          "RestoreShouldReboot":       false,  ← we handle reboot prompt in UI
    ///          "RestorePreserveCameraRoll": true,
    ///          "RestorePreserveSettings":   true
    ///        }
    ///   6. Message pump loop:
    ///        DLMessageDownloadFiles  → send file data from backupDir
    ///        DLContentsOfDirectory   → send directory listing
    ///        DLMessageProcessMessage → parse result, check for errors
    ///        DLMessageDisconnect     → break loop
    ///
    /// Alternative: link libimobiledevice as a static lib and call
    ///   mobilebackup2_client_new() / mobilebackup2_send_request() directly.
    ///   See: https://github.com/libimobiledevice/libimobiledevice
    ///
    /// jkcoxson's rusty_libimobiledevice (Rust) is another reference:
    ///   https://github.com/jkcoxson/rusty_libimobiledevice
    ///
    /// ════════════════════════════════════════════════════════

    private func triggerBookRestore(backupDir: URL) async throws {

        // TODO: Replace this stub with the mobilebackup2 client from Nugget.
        //
        // Until implemented, we simulate the restore for UI testing purposes.
        // Remove the simulation block below once the real client is integrated.

        #if DEBUG
        // Simulate restore for UI development
        for i in stride(from: 0.6, through: 0.95, by: 0.05) {
            try await Task.sleep(nanoseconds: 200_000_000)
            setProgress(i)
        }
        // In debug, succeed to allow UI testing
        // Comment out the line below to surface the notImplemented error instead:
        return
        #endif

        throw EngineError.notImplemented(
            """
            mobilebackup2 client not yet wired up.
            Copy BookRestoreManager.swift from:
            github.com/leminlimez/Nugget
            into this triggerBookRestore() function.
            """
        )
    }

    // MARK: - Helpers

    private func setProgress(_ value: Double) {
        DispatchQueue.main.async {
            self.progress = value
        }
    }
}

// MARK: - Errors

enum EngineError: Error, LocalizedError {
    case noPairingFile
    case minimuxerFailed
    case notImplemented(String)

    var errorDescription: String? {
        switch self {
        case .noPairingFile:
            return "No pairing file found. Import your .mobiledevicepairing file first."
        case .minimuxerFailed:
            return "minimuxer failed to start. Check Developer Mode is enabled."
        case .notImplemented(let msg):
            return msg
        }
    }
}
