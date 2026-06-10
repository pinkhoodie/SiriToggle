import Foundation
import CryptoKit

// MARK: - libimobiledevice Restore Strategy

/// Restore strategy that uses libimobiledevice's C API via a bridging header.
///
/// This is the fastest and most reliable method, using the battle-tested
/// libimobiledevice C library directly. It requires linking the library
/// as either a static XCFramework or via system package manager (brew on macOS).
///
/// Setup instructions:
///   1. Install libimobiledevice:  brew install libimobiledevice
///   2. Add to Bridging-Header.h:  #import <libimobiledevice/libimobiledevice.h>
///                                #import <libimobiledevice/mobilebackup2.h>
///                                #import <libimobiledevice/lockdown.h>
///   3. Link library: Add -limobiledevice to Other Linker Flags
///   4. Or use XCFramework: Drag libimobiledevice.xcframework into Frameworks/
///
/// Reference: https://github.com/libimobiledevice/libimobiledevice
struct LibIMDRestoreStrategy: RestoreStrategyProtocol {

    static var displayName: String { "libimobiledevice" }
    static var description: String {
        "Uses libimobiledevice's C API directly. Fastest and most reliable. "
        + "Requires linking libimobiledevice (brew install libimobiledevice or XCFramework). "
        + "Best for macOS builds where you control the environment."
    }
    static var requiresLibIMD: Bool { true }
    static var requiresPython: Bool { false }
    static var worksOnDevice: Bool { false }

    func restore(backupDir: URL, progress: @escaping (Double) -> Void) async throws {
        guard FileManager.default.fileExists(atPath: backupDir.path) else {
            throw RestoreError.backupDirNotFound
        }

        // Check if libimobiledevice symbols are available
        guard libIMDAvailable else {
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

    // MARK: - C Library Interface

    /// Check if libimobiledevice symbols are linked and available.
    private var libIMDAvailable: Bool {
        // Attempt to get the address of a known symbol
        // If libimobiledevice is linked, idevice_new will be resolvable
        let handle = dlopen("libimobiledevice-1.0.dylib", RTLD_NOW)
        if handle == nil {
            // Try without version suffix
            _ = dlopen("libimobiledevice.dylib", RTLD_NOW)
        }
        // Also check common system paths
        let symbol = dlsym(RTLD_DEFAULT, "idevice_new")
        return symbol != nil
    }

    /// Main restore implementation using libimobiledevice C API.
    private func performRestore(backupDir: URL, progress: @escaping (Double) -> Void) throws {
        var device: OpaquePointer? = nil
        var lockdown: OpaquePointer? = nil
        var mobilebackup2: OpaquePointer? = nil

        defer {
            if mobilebackup2 != nil { mobilebackup2_client_free(mobilebackup2) }
            if lockdown != nil { lockdownd_client_free(lockdown) }
            if device != nil { idevice_free(device) }
        }

        // Step 1: Get the default device (USB via usbmuxd, or network)
        progress(0.60)
        var ret = idevice_new(&device, nil)
        guard ret == IDEVICE_E_SUCCESS else {
            throw RestoreError.connectionFailed("idevice_new failed: \(ret)")
        }

        // Step 2: Connect to lockdown
        progress(0.63)
        ret = lockdownd_client_new_with_handshake(device, &lockdown, "SiriToggle")
        guard ret == LOCKDOWN_E_SUCCESS else {
            throw RestoreError.connectionFailed("lockdownd_client_new_with_handshake failed: \(ret)")
        }

        // Step 3: Start mobilebackup2 service
        progress(0.66)
        var service: lockdownd_service_descriptor_t? = nil
        ret = lockdownd_start_service(lockdown, "com.apple.mobilebackup2", &service)
        guard ret == LOCKDOWN_E_SUCCESS, let svc = service else {
            throw RestoreError.connectionFailed("lockdownd_start_service failed: \(ret)")
        }
        defer { lockdownd_service_descriptor_free(svc) }

        // Step 4: Create mobilebackup2 client
        progress(0.70)
        ret = mobilebackup2_client_new(device, svc, &mobilebackup2)
        guard ret == MOBILEBACKUP2_E_SUCCESS else {
            throw RestoreError.connectionFailed("mobilebackup2_client_new failed: \(ret)")
        }

        // Step 5: Send version exchange
        progress(0.72)
        let versions: [Int32] = [300, 400]
        var versionReceived: Int32 = 0
        ret = mobilebackup2_version_exchange(
            mobilebackup2,
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
        ret = mobilebackup2_send_request(
            mobilebackup2,
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
        try runMessagePump(mobilebackup2: mobilebackup2!, backupDir: backupDir, progress: progress)

        // Step 8: Send disconnect
        progress(0.95)
        mobilebackup2_send_raw(mobilebackup2, nil, 0)
    }

    /// Message pump that processes DLMessage responses from the device.
    private func runMessagePump(mobilebackup2: OpaquePointer, backupDir: URL, progress: @escaping (Double) -> Void) throws {
        var currentProgress = 0.80

        while true {
            var message: UnsafeMutablePointer<Int8>? = nil
            var messageSize: UInt32 = 0

            let ret = mobilebackup2_receive_raw(mobilebackup2, &message, &messageSize)
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
                    try handleDownloadFiles(mobilebackup2: mobilebackup2, message: array, backupDir: backupDir)
                    currentProgress += 0.01
                    progress(min(currentProgress, 0.94))

                case "DLContentsOfDirectory":
                    try handleContentsOfDirectory(mobilebackup2: mobilebackup2, message: array, backupDir: backupDir)

                case "DLMessageCreateDirectory":
                    try sendStatusResponse(mobilebackup2: mobilebackup2, statusCode: 0)

                case "DLMessageProcessMessage":
                    if try handleProcessMessage(mobilebackup2: mobilebackup2, message: array) {
                        return  // restore complete
                    }

                case "DLMessageDisconnect":
                    return

                case "DLPing":
                    try sendStatusResponse(mobilebackup2: mobilebackup2, statusCode: 0)

                default:
                    try sendStatusResponse(mobilebackup2: mobilebackup2, statusCode: 0)
                }
            }
        }
    }

    /// Handle DLMessageDownloadFiles using libimobiledevice send functions.
    private func handleDownloadFiles(mobilebackup2: OpaquePointer, message: [Any], backupDir: URL) throws {
        guard message.count >= 2,
              let fileList = message[1] as? [String] else {
            try sendStatusResponse(mobilebackup2: mobilebackup2, statusCode: -6)
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
                    mobilebackup2_send_raw(
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
                    mobilebackup2_send_raw(
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
            mobilebackup2_send_raw(
                mobilebackup2,
                rawBuffer.baseAddress?.assumingMemoryBound(to: Int8.self),
                UInt32(statusData.count)
            )
        }
    }

    /// Handle DLContentsOfDirectory.
    private func handleContentsOfDirectory(mobilebackup2: OpaquePointer, message: [Any], backupDir: URL) throws {
        guard message.count >= 2,
              let dirPath = message[1] as? String else {
            try sendStatusResponse(mobilebackup2: mobilebackup2, statusCode: -6)
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
            mobilebackup2_send_raw(
                mobilebackup2,
                rawBuffer.baseAddress?.assumingMemoryBound(to: Int8.self),
                UInt32(data.count)
            )
        }
    }

    /// Handle DLMessageProcessMessage — check for completion or errors.
    private func handleProcessMessage(mobilebackup2: OpaquePointer, message: [Any]) throws -> Bool {
        guard message.count >= 2,
              let processMsg = message[1] as? [String: Any] else {
            try sendStatusResponse(mobilebackup2: mobilebackup2, statusCode: -6)
            return false
        }

        if let errorCode = processMsg["ErrorCode"] as? Int, errorCode != 0 {
            let errorMsg = processMsg["ErrorDescription"] as? String ?? "Unknown"
            throw RestoreError.restoreRequestRejected("Error \(errorCode): \(errorMsg)")
        }

        if let messageName = processMsg["MessageName"] as? String,
           (messageName.contains("Finished") || messageName.contains("Complete")) {
            try sendStatusResponse(mobilebackup2: mobilebackup2, statusCode: 0)
            return true
        }

        try sendStatusResponse(mobilebackup2: mobilebackup2, statusCode: 0)
        return false
    }

    /// Send a status response message.
    private func sendStatusResponse(mobilebackup2: OpaquePointer, statusCode: Int) throws {
        let msg: [Any] = ["DLMessageStatusResponse", statusCode as UInt32]
        let data = try PropertyListSerialization.data(fromPropertyList: msg, format: .binary, options: 0)
        data.withUnsafeBytes { rawBuffer in
            mobilebackup2_send_raw(
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

// These mirror the libimobiledevice C headers.
// When libimobiledevice is properly linked, these should come from the headers.
// These declarations serve as fallback definitions for compilation.

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

// MARK: - C Function Declarations

// These will resolve when libimobiledevice is linked.
// They are declared as optional (@_silgen_name) so compilation succeeds
// even without the library — runtime availability is checked via libIMDAvailable.

@_silgen_name("idevice_new")
private func idevice_new(_ device: UnsafeMutablePointer<idevice_t?>?, _ udid: UnsafePointer<CChar>?) -> idevice_error_t

@_silgen_name("idevice_free")
private func idevice_free(_ device: idevice_t)

@_silgen_name("lockdownd_client_new_with_handshake")
private func lockdownd_client_new_with_handshake(
    _ device: idevice_t,
    _ client: UnsafeMutablePointer<lockdownd_client_t?>?,
    _ label: UnsafePointer<CChar>?
) -> lockdownd_error_t

@_silgen_name("lockdownd_client_free")
private func lockdownd_client_free(_ client: lockdownd_client_t)

@_silgen_name("lockdownd_start_service")
private func lockdownd_start_service(
    _ client: lockdownd_client_t,
    _ service: UnsafePointer<CChar>?,
    _ descriptor: UnsafeMutablePointer<lockdownd_service_descriptor_t?>?
) -> lockdownd_error_t

@_silgen_name("lockdownd_service_descriptor_free")
private func lockdownd_service_descriptor_free(_ service: lockdownd_service_descriptor_t)

@_silgen_name("mobilebackup2_client_new")
private func mobilebackup2_client_new(
    _ device: idevice_t,
    _ service: lockdownd_service_descriptor_t,
    _ client: UnsafeMutablePointer<mobilebackup2_client_t?>?
) -> mobilebackup2_error_t

@_silgen_name("mobilebackup2_client_free")
private func mobilebackup2_client_free(_ client: mobilebackup2_client_t)

@_silgen_name("mobilebackup2_version_exchange")
private func mobilebackup2_version_exchange(
    _ client: mobilebackup2_client_t,
    _ local_versions: UnsafePointer<Int32>?,
    _ count: Int32,
    _ remote_version: UnsafeMutablePointer<Int32>?,
    _ match: UnsafePointer<CChar>?
) -> mobilebackup2_error_t

@_silgen_name("mobilebackup2_send_request")
private func mobilebackup2_send_request(
    _ client: mobilebackup2_client_t,
    _ request: UnsafePointer<CChar>?,
    _ backupPath: UnsafePointer<CChar>?,
    _ opts: UnsafePointer<CChar>?,
    _ dlmessage: UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>?
) -> mobilebackup2_error_t

@_silgen_name("mobilebackup2_receive_raw")
private func mobilebackup2_receive_raw(
    _ client: mobilebackup2_client_t,
    _ data: UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>?,
    _ size: UnsafeMutablePointer<UInt32>?
) -> mobilebackup2_error_t

@_silgen_name("mobilebackup2_send_raw")
private func mobilebackup2_send_raw(
    _ client: mobilebackup2_client_t,
    _ data: UnsafePointer<Int8>?,
    _ length: UInt32
) -> mobilebackup2_error_t
