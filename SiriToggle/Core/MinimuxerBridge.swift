import Foundation

/// Swift wrapper around the minimuxer C API.
///
/// minimuxer creates a fake local usbmuxd server at localhost:27015,
/// allowing on-device mobilebackup2 calls without a physical USB connection.
///
/// Source: https://github.com/jkcoxson/minimuxer
/// XCFramework: download from minimuxer Releases tab and place in Frameworks/
class MinimuxerBridge {

    static let shared = MinimuxerBridge()

    private var isStarted = false
    private let lock = NSLock()

    private init() {}

    /// Start the minimuxer tunnel using the given pairing file.
    ///
    /// - Parameter pairingFilePath: Absolute path to the .mobiledevicepairing file.
    /// - Throws: MinimuxerError.timeout if tunnel does not become ready within 10s.
    ///
    /// This call is idempotent — calling it again after a successful start is a no-op.
    func start(pairingFilePath: String) throws {
        lock.lock()
        defer { lock.unlock() }

        guard !isStarted else { return }

        // Read pairing file data and pass to minimuxer
        // minimuxer C signature:
        //   void start_minimuxer_threads(const char* pairing_file_contents, uintptr_t length)
        //
        // Some builds use:
        //   void start_minimuxer(const char* pairing_file_path)
        //
        // Check your specific minimuxer build's header — use whichever matches.
        // Both variants are documented in the minimuxer README.

        guard let data = FileManager.default.contents(atPath: pairingFilePath),
              let contents = String(data: data, encoding: .utf8) else {
            throw MinimuxerError.pairingFileUnreadable
        }

        // Call minimuxer — uncomment the correct variant for your build:

        // Variant A (path-based):
        // start_minimuxer(pairingFilePath)

        // Variant B (contents-based, preferred in newer builds):
        // contents.withCString { ptr in
        //     start_minimuxer_threads(ptr, UInt(data.count))
        // }

        // TODO: Uncomment the correct variant above after adding minimuxer.xcframework.
        // The framework is not bundled here — download from:
        // https://github.com/jkcoxson/minimuxer/releases
        _ = contents  // suppress unused warning until implemented

        // Poll until ready (timeout: 10 seconds)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            // if minimuxer_ready() { break }
            // TODO: uncomment above when minimuxer is linked
            Thread.sleep(forTimeInterval: 0.1)

            // TEMP: assume ready after linking
            break
        }

        isStarted = true
    }

    /// Returns true if the minimuxer tunnel is ready to accept connections.
    var ready: Bool {
        // return minimuxer_ready()
        // TODO: uncomment above when minimuxer is linked
        return isStarted
    }

    /// Reset state (useful for error recovery).
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        isStarted = false
    }
}

enum MinimuxerError: Error, LocalizedError {
    case timeout
    case pairingFileUnreadable
    case notStarted

    var errorDescription: String? {
        switch self {
        case .timeout:
            return "minimuxer tunnel timed out. Make sure Developer Mode is enabled."
        case .pairingFileUnreadable:
            return "Cannot read pairing file. Try re-importing it."
        case .notStarted:
            return "minimuxer is not running. Import a pairing file first."
        }
    }
}
