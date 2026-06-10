import Foundation
import UniformTypeIdentifiers

/// Manages the .mobiledevicepairing file required by minimuxer.
/// The file is stored persistently in the app's Documents directory.
@MainActor
class PairingFileManager: ObservableObject {

    static let shared = PairingFileManager()

    private let fileName = "device.mobiledevicepairing"

    /// Full path to the stored pairing file, or nil if not yet imported.
    var pairingFilePath: String? {
        let url = documentsURL.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url.path : nil
    }

    @Published var hasPairingFile: Bool = false

    private var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    private init() {
        hasPairingFile = pairingFilePath != nil
    }

    /// Import a pairing file from a security-scoped URL (from UIDocumentPickerViewController / fileImporter).
    func importPairingFile(from sourceURL: URL) throws {
        guard sourceURL.startAccessingSecurityScopedResource() else {
            throw PairingError.accessDenied
        }
        defer { sourceURL.stopAccessingSecurityScopedResource() }

        let dest = documentsURL.appendingPathComponent(fileName)

        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: sourceURL, to: dest)

        hasPairingFile = true
    }

    /// Remove the stored pairing file.
    func removePairingFile() throws {
        guard let path = pairingFilePath else { return }
        try FileManager.default.removeItem(atPath: path)
        hasPairingFile = false
    }
}

enum PairingError: Error, LocalizedError {
    case accessDenied
    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Could not access the selected file. Make sure you grant permission."
        }
    }
}
