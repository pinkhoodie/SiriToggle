import Foundation
import CryptoKit
import Darwin

// MARK: - libimobiledevice Restore Strategy

/// Restore strategy that uses libimobiledevice's C API via dynamic loading.
///
/// This is the fastest and most reliable method, using the battle-tested
/// libimobiledevice C library directly. On macOS it loads from Homebrew;
/// on iOS it gracefully falls back since the library is not available.
///
/// Setup instructions (macOS only):
///   1. Install libimobiledevice:  brew install libimobiledevice
///   2. No project changes needed — everything is resolved at runtime
///
/// Reference: https://github.com/libimobiledevice/libimobiledevice
struct LibIMDRestoreStrategy: RestoreStrategyProtocol {

    static var displayName: String { "libimobiledevice" }
    static var description: String {
        "Uses libimobiledevice's C API via dynamic loading. Fastest and most reliable. "
        + "Requires libimobiledevice installed (brew install libimobiledevice). "
        + "Only works on macOS; automatically unavailable on iOS."
    }
    static var requiresLibIMD: Bool { true }
    static var requiresPython: Bool { false }
    static var worksOnDevice: Bool { false }

    func restore(backupDir: URL, progress: @escaping (Double) -> Void) async throws {
        guard FileManager.default.fileExists(atPath: backupDir.path) else {
            throw RestoreError.backupDirNotFound
        }

        // Check if libimobiledevice symbols are available
        guard LibIMDLoader.shared.isAvailable else {
            throw RestoreError.libIMDNotLinked
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try self.performRestore(backupDir: backupDir, progress: progress)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Restore Implementation

    /// Main restore implementation using dynamically-loaded libimobiledevice C API.
    private func performRestore(backupDir: URL, progress: @escaping (Double) -> Void) throws {
        let lib = LibIMDLoader.shared

        var device: OpaquePointer? = nil
        var lockdown: OpaquePointer? = nil
        var mobilebackup2: OpaquePointer? = nil

        defer {
            if let mb2 = mobilebackup2 { lib.mobilebackup2_client_free(mb2) }
            if let ld = lockdown { lib.lockdownd_client_free(ld) }
            if let dev = device { lib.idevice_free(dev) }
        }

        // Step 1: Get the default device (USB via usbmuxd, or network)
        progress(0.60)
        var ret = lib.idevice_new(&device, nil)
        guard ret == IDEVICE_E_SUCCESS else {
            throw RestoreError.connectionFailed("idevice_new failed: \(ret)")
        }

        // Step 2: Connect to lockdown
        progress(0.63)
        ret = lib.lockdownd_client_new_with_handshake(device!, &lockdown, "SiriToggle")
        guard ret == LOCKDOWN_E_SUCCESS else {
            throw RestoreError.connectionFailed("lockdownd_client_new_with_handshake failed: \(ret)")
        }

        // Step 3: Start mobilebackup2 service
        progress(0.66)
        var service: lockdownd_service_descriptor_t? = nil
        ret = lib.lockdownd_start_service(lockdown!, "com.apple.mobilebackup2", &service)
        guard ret == LOCKDOWN_E_SUCCESS, let svc = service else {
            throw RestoreError.connectionFailed("lockdownd_start_service failed: \(ret)")
        }
        defer { lib.lockdownd_service_descriptor_free(svc) }

        // Step 4: Create mobilebackup2 client
        progress(0.70)
        ret = lib.mobilebackup2_client_new(device!, svc, &mobilebackup2)
        guard ret == MOBILEBACKUP2_E_SUCCESS else {
            throw RestoreError.connectionFailed("mobilebackup2_client_new failed: \(ret)")
        }

        // Step 5: Send version exchange
        progress(0.72)
        let versions: [Int32] = [300, 400]
        var versionReceived: Int32 = 0
        ret = lib.mobilebackup2_version_exchange(
            mobilebackup2!,
            versions,
            Int32(versions.count),
            &versionReceived,
            "4.0"
        )
        guard ret == MOBILEBACKUP2_E_SUCCESS else {
            throw RestoreError.versionExchangeFailed
        }

        // Step 6: Send restore request with options
        progress(0.75)
        let options: [String: Any] = [
            "RestoreSystemFiles":        true,
            "RemoveItemsNotRestored":    false,
            "RestoreShouldReboot":       false,
            "RestorePreserveCameraRoll": true,
            "RestorePreserveSettings":   true,
            "RestorePreserveUserAccounts": true
        ]
        let optionsData = try PropertyListSerialization.data(fromPropertyList: options, format: .xml, options: 0)
        guard let optionsString = String(data: optionsData, encoding: .utf8) else {
            throw RestoreError.restoreRequestRejected("Failed to serialize options")
        }

        let backupPath = backupDir.path
        ret = lib.mobilebackup2_send_request(
            mobilebackup2!,
            "Restore",
            backupPath,
            optionsString,
            nil
        )
        guard ret == MOBILEBACKUP2_E_SUCCESS else {
            throw RestoreError.restoreRequestRejected("mobilebackup2_send_request failed: \(ret)")
        }

        // Step 7: Message pump — handle DLMessages
        progress(0.80)
        try runMessagePump(lib: lib, mobilebackup2: mobilebackup2!, backupDir: backupDir, progress: progress)

        // Step 8: Send disconnect
        progress(0.95)
        lib.mobilebackup2_send_raw(mobilebackup2!, nil, 0)
    }

    /// Message pump that processes DLMessage responses from the device.
    private func runMessagePump(lib: LibIMDLoader, mobilebackup2: OpaquePointer, backupDir: URL, progress: @escaping (Double) -> Void) throws {
        var currentProgress = 0.80

        while true {
            var message: UnsafeMutablePointer<Int8>? = nil
            var messageSize: UInt32 = 0

            let ret = lib.mobilebackup2_receive_raw(mobilebackup2, &message, &messageSize)
            defer { free(message) }

            guard ret == MOBILEBACKUP2_E_SUCCESS else {
                if ret == MOBILEBACKUP2_E_INVALID_ARG {
                    // Graceful disconnect
                    break
                }
                throw RestoreError.unexpectedMessage("receive_raw failed: \(ret)")
            }

            guard let msgData = message, messageSize > 0 else {
                break  // disconnect
            }

            // Parse plist from raw data
            let data = Data(bytesNoCopy: msgData, count: Int(messageSize), deallocator: .none)
            guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else {
                continue
            }

            if let array = plist as? [Any],
               let msgType = array.first as? String {

                switch msgType {
                case "DLMessageDownloadFiles":
                    try handleDownloadFiles(lib: lib, mobilebackup2: mobilebackup2, message: array, backupDir: backupDir)
                    currentProgress += 0.01
                    progress(min(currentProgress, 0.94))

                case "DLContentsOfDirectory":
                    try handleContentsOfDirectory(lib: lib, mobilebackup2: mobilebackup2, message: array, backupDir: backupDir)

                case "DLMessageCreateDirectory":
                    try sendStatusResponse(lib: lib, mobilebackup2: mobilebackup2, statusCode: 0)

                case "DLMessageProcessMessage":
                    if try handleProcessMessage(lib: lib, mobilebackup2: mobilebackup2, message: array) {
                        return  // restore complete
                    }

                case "DLMessageDisconnect":
                    return

                case "DLPing":
                    try sendStatusResponse(lib: lib, mobilebackup2: mobilebackup2, statusCode: 0)

                default:
                    try sendStatusResponse(lib: lib, mobilebackup2: mobilebackup2, statusCode: 0)
                }
            }
        }
    }

    /// Handle DLMessageDownloadFiles using libimobiledevice send functions.
    private func handleDownloadFiles(lib: LibIMDLoader, mobilebackup2: OpaquePointer, message: [Any], backupDir: URL) throws {
        guard message.count >= 2,
              let fileList = message[1] as? [String] else {
            try sendStatusResponse(lib: lib, mobilebackup2: mobilebackup2, statusCode: -6)
            return
        }

        var errors: [String: String?] = [:]

        for filePath in fileList {
            let fileID = sha1Hex(filePath)
            let fileURL = backupDir.appendingPathComponent(fileID)

            if FileManager.default.fileExists(atPath: fileURL.path),
               let fileData = try? Data(contentsOf: fileURL) {
                // Send file data
                let ret = fileData.withUnsafeBytes { rawBuffer in
                    lib.mobilebackup2_send_raw(
                        mobilebackup2,
                        rawBuffer.baseAddress?.assumingMemoryBound(to: Int8.self),
                        UInt32(fileData.count)
                    )
                }
                if ret == MOBILEBACKUP2_E_SUCCESS {
                    errors[filePath] = nil
                } else {
                    errors[filePath] = "Send failed"
                }
            } else {
                // Send 0-length for missing file
                var zero: Int32 = 0
                withUnsafeBytes(of: &zero) { rawBuffer in
                    lib.mobilebackup2_send_raw(
                        mobilebackup2,
                        rawBuffer.baseAddress?.assumingMemoryBound(to: Int8.self),
                        4
                    )
                }
                errors[filePath] = "File not found"
            }
        }

        // Send status response as plist
        let statusMsg: [Any] = [
            "DLMessageStatusResponse",
            errors as NSDictionary,
            0 as UInt32
        ]
        let statusData = try PropertyListSerialization.data(fromPropertyList: statusMsg, format: .binary, options: 0)
        statusData.withUnsafeBytes { rawBuffer in
            lib.mobilebackup2_send_raw(
                mobilebackup2,
                rawBuffer.baseAddress?.assumingMemoryBound(to: Int8.self),
                UInt32(statusData.count)
            )
        }
    }

    /// Handle DLContentsOfDirectory.
    private func handleContentsOfDirectory(lib: LibIMDLoader, mobilebackup2: OpaquePointer, message: [Any], backupDir: URL) throws {
        guard message.count >= 2,
              let dirPath = message[1] as? String else {
            try sendStatusResponse(lib: lib, mobilebackup2: mobilebackup2, statusCode: -6)
            return
        }

        let url = backupDir.appendingPathComponent(dirPath)
        var contents: [[String: Any]] = []

        if let files = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
            for file in files {
                let attr = try? FileManager.default.attributesOfItem(atPath: file.path)
                var entry: [String: Any] = [
                    "DLFileType": attr?[.type] as? FileAttributeType == .typeDirectory ? "DLFileTypeDirectory" : "DLFileTypeRegular",
                    "DLFileSize": attr?[.size] as? UInt64 ?? 0,
                    "DLFileModificationDate": attr?[.modificationDate] as? Date ?? Date()
                ]
                contents.append(entry)
            }
        }

        let response: [Any] = [
            "DLMessageStatusResponse",
            contents as NSArray,
            0 as UInt32
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: response, format: .binary, options: 0)
        data.withUnsafeBytes { rawBuffer in
            lib.mobilebackup2_send_raw(
                mobilebackup2,
                rawBuffer.baseAddress?.assumingMemoryBound(to: Int8.self),
                UInt32(data.count)
            )
        }
    }

    /// Handle DLMessageProcessMessage — check for completion or errors.
    private func handleProcessMessage(lib: LibIMDLoader, mobilebackup2: OpaquePointer, message: [Any]) throws -> Bool {
        guard message.count >= 2,
              let processMsg = message[1] as? [String: Any] else {
            try sendStatusResponse(lib: lib, mobilebackup2: mobilebackup2, statusCode: -6)
            return false
        }

        if let errorCode = processMsg["ErrorCode"] as? Int, errorCode != 0 {
            let errorMsg = processMsg["ErrorDescription"] as? String ?? "Unknown"
            throw RestoreError.restoreRequestRejected("Error \(errorCode): \(errorMsg)")
        }

        if let messageName = processMsg["MessageName"] as? String,
           (messageName.contains("Finished") || messageName.contains("Complete")) {
            try sendStatusResponse(lib: lib, mobilebackup2: mobilebackup2, statusCode: 0)
            return true
        }

        try sendStatusResponse(lib: lib, mobilebackup2: mobilebackup2, statusCode: 0)
        return false
    }

    /// Send a status response message.
    private func sendStatusResponse(lib: LibIMDLoader, mobilebackup2: OpaquePointer, statusCode: Int) throws {
        let msg: [Any] = ["DLMessageStatusResponse", UInt32(statusCode)]
        let data = try PropertyListSerialization.data(fromPropertyList: msg, format: .binary, options: 0)
        data.withUnsafeBytes { rawBuffer in
            lib.mobilebackup2_send_raw(
                mobilebackup2,
                rawBuffer.baseAddress?.assumingMemoryBound(to: Int8.self),
                UInt32(data.count)
            )
        }
    }

    /// SHA1 hex digest.
    private func sha1Hex(_ input: String) -> String {
        let data = Data(input.utf8)
        let digest = Insecure.SHA1.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - C API Type Aliases and Constants

private typealias idevice_t = OpaquePointer
private typealias lockdownd_client_t = OpaquePointer
private typealias mobilebackup2_client_t = OpaquePointer
private typealias lockdownd_service_descriptor_t = OpaquePointer?

private let IDEVICE_E_SUCCESS: idevice_error_t = 0
private typealias idevice_error_t = Int32

private let LOCKDOWN_E_SUCCESS: lockdownd_error_t = 0
private typealias lockdownd_error_t = Int32

private let MOBILEBACKUP2_E_SUCCESS: mobilebackup2_error_t = 0
private let MOBILEBACKUP2_E_INVALID_ARG: mobilebackup2_error_t = -1
private typealias mobilebackup2_error_t = Int32

// MARK: - Dynamic Loader

/// Dynamically loads libimobiledevice functions at runtime using dlopen/dlsym.
/// This avoids linker errors when the library is not present (e.g., on iOS).
final class LibIMDLoader {

    static let shared = LibIMDLoader()

    /// Whether libimobiledevice was successfully loaded and all symbols resolved.
    private(set) var isAvailable: Bool = false

    // Function pointer types matching libimobiledevice C API
    typealias idevice_new_fn = @convention(c) (
        UnsafeMutablePointer<OpaquePointer?>?,
        UnsafePointer<CChar>?
    ) -> Int32

    typealias idevice_free_fn = @convention(c) (
        OpaquePointer
    ) -> Void

    typealias lockdownd_client_new_with_handshake_fn = @convention(c) (
        OpaquePointer,
        UnsafeMutablePointer<OpaquePointer?>?,
        UnsafePointer<CChar>?
    ) -> Int32

    typealias lockdownd_client_free_fn = @convention(c) (
        OpaquePointer
    ) -> Void

    typealias lockdownd_start_service_fn = @convention(c) (
        OpaquePointer,
        UnsafePointer<CChar>?,
        UnsafeMutablePointer<OpaquePointer?>?
    ) -> Int32

    typealias lockdownd_service_descriptor_free_fn = @convention(c) (
        OpaquePointer?
    ) -> Void

    typealias mobilebackup2_client_new_fn = @convention(c) (
        OpaquePointer,
        OpaquePointer?,
        UnsafeMutablePointer<OpaquePointer?>?
    ) -> Int32

    typealias mobilebackup2_client_free_fn = @convention(c) (
        OpaquePointer
    ) -> Void

    typealias mobilebackup2_version_exchange_fn = @convention(c) (
        OpaquePointer,
        UnsafePointer<Int32>?,
        Int32,
        UnsafeMutablePointer<Int32>?,
        UnsafePointer<CChar>?
    ) -> Int32

    typealias mobilebackup2_send_request_fn = @convention(c) (
        OpaquePointer,
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?,
        UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>?
    ) -> Int32

    typealias mobilebackup2_receive_raw_fn = @convention(c) (
        OpaquePointer,
        UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>?,
        UnsafeMutablePointer<UInt32>?
    ) -> Int32

    typealias mobilebackup2_send_raw_fn = @convention(c) (
        OpaquePointer,
        UnsafePointer<Int8>?,
        UInt32
    ) -> Int32

    // Function pointer storage
    private(set) var idevice_new: idevice_new_fn!
    private(set) var idevice_free: idevice_free_fn!
    private(set) var lockdownd_client_new_with_handshake: lockdownd_client_new_with_handshake_fn!
    private(set) var lockdownd_client_free: lockdownd_client_free_fn!
    private(set) var lockdownd_start_service: lockdownd_start_service_fn!
    private(set) var lockdownd_service_descriptor_free: lockdownd_service_descriptor_free_fn!
    private(set) var mobilebackup2_client_new: mobilebackup2_client_new_fn!
    private(set) var mobilebackup2_client_free: mobilebackup2_client_free_fn!
    private(set) var mobilebackup2_version_exchange: mobilebackup2_version_exchange_fn!
    private(set) var mobilebackup2_send_request: mobilebackup2_send_request_fn!
    private(set) var mobilebackup2_receive_raw: mobilebackup2_receive_raw_fn!
    private(set) var mobilebackup2_send_raw: mobilebackup2_send_raw_fn!

    private init() {
        // Attempt to load libimobiledevice
        let handle = loadLibrary()
        guard handle != nil else {
            isAvailable = false
            return
        }

        // Resolve all required symbols
        guard resolveAllSymbols(handle: handle!) else {
            isAvailable = false
            // Don't dlclose — the library may be needed by other code
            return
        }

        isAvailable = true
    }

    /// Try to load libimobiledevice from various known paths.
    private func loadLibrary() -> UnsafeMutableRawPointer? {
        let paths = [
            // Homebrew Apple Silicon
            "/opt/homebrew/lib/libimobiledevice-1.0.dylib",
            // Homebrew Intel
            "/usr/local/lib/libimobiledevice-1.0.dylib",
            // MacPorts
            "/opt/local/lib/libimobiledevice-1.0.dylib",
            // Unversioned fallback
            "/opt/homebrew/lib/libimobiledevice.dylib",
            "/usr/local/lib/libimobiledevice.dylib",
            // System search path (will find if in DYLD_LIBRARY_PATH)
            "libimobiledevice-1.0.dylib",
            "libimobiledevice.dylib",
        ]

        for path in paths {
            if let handle = dlopen(path, RTLD_NOW | RTLD_GLOBAL) {
                return handle
            }
        }

        return nil
    }

    /// Resolve all required symbols from the loaded library.
    private func resolveAllSymbols(handle: UnsafeMutableRawPointer) -> Bool {
        let symbols: [(String, UnsafeMutableRawPointer?) -> Bool] = [
            resolve("idevice_new",                \.idevice_new),
            resolve("idevice_free",               \.idevice_free),
            resolve("lockdownd_client_new_with_handshake", \.lockdownd_client_new_with_handshake),
            resolve("lockdownd_client_free",      \.lockdownd_client_free),
            resolve("lockdownd_start_service",    \.lockdownd_start_service),
            resolve("lockdownd_service_descriptor_free", \.lockdownd_service_descriptor_free),
            resolve("mobilebackup2_client_new",   \.mobilebackup2_client_new),
            resolve("mobilebackup2_client_free",  \.mobilebackup2_client_free),
            resolve("mobilebackup2_version_exchange", \.mobilebackup2_version_exchange),
            resolve("mobilebackup2_send_request", \.mobilebackup2_send_request),
            resolve("mobilebackup2_receive_raw",  \.mobilebackup2_receive_raw),
            resolve("mobilebackup2_send_raw",     \.mobilebackup2_send_raw),
        ]

        for sym in symbols {
            if !sym(handle) { return false }
        }

        return true
    }

    /// Helper to resolve a single symbol and assign it to the given keypath.
    private func resolve<T>(_ name: String, _ keyPath: ReferenceWritableKeyPath<LibIMDLoader, T>) -> (UnsafeMutableRawPointer) -> Bool {
        return { handle in
            guard let ptr = dlsym(handle, name) else {
                return false
            }
            self[keyPath: keyPath] = unsafeBitCast(ptr, to: T.self)
            return true
        }
    }
}
