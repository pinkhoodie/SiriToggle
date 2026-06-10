import Foundation
import SQLite3
import CryptoKit

/// Represents a single file to include in the BookRestore backup.
struct BackupFile {
    let domain: String        // iTunes backup domain (e.g. "RootDomain")
    let relativePath: String  // Path relative to domain root
    let data: Data            // File contents

    /// iTunes backup file name = lowercase SHA1 hex of file content.
    var fileID: String {
        let digest = Insecure.SHA1.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Builds a minimal but valid iTunes/Finder backup directory structure
/// suitable for triggering a BookRestore via com.apple.mobilebackup2.
///
/// Backup structure:
///   <backupDir>/
///     Info.plist
///     Manifest.plist
///     Manifest.db       ← SQLite database mapping fileID → domain/path
///     Status.plist
///     <sha1>            ← Each file, named by SHA1 of its content
///
/// Reference: https://gist.github.com/leminlimez/c602c067349140fe979410ef69d39c28
struct BackupManifestBuilder {

    /// Build the full backup directory in a temp location.
    /// - Parameter files: The files to include in the restore.
    /// - Returns: URL to the backup root directory.
    static func buildBackup(files: [BackupFile]) throws -> URL {
        let backupDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SiriToggleBackup_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)

        // Write each file named by its SHA1
        for file in files {
            let fileURL = backupDir.appendingPathComponent(file.fileID)
            try file.data.write(to: fileURL)
        }

        // Build the four required metadata files
        try writeManifestDB(to: backupDir, files: files)
        try writeManifestPlist(to: backupDir)
        try writeInfoPlist(to: backupDir)
        try writeStatusPlist(to: backupDir)

        return backupDir
    }

    // MARK: - Manifest.db

    /// Builds the SQLite Manifest.db that maps each file's SHA1 to its
    /// domain and relative path within that domain.
    private static func writeManifestDB(to dir: URL, files: [BackupFile]) throws {
        let dbPath = dir.appendingPathComponent("Manifest.db").path
        var db: OpaquePointer?

        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            throw BackupError.sqliteOpenFailed
        }
        defer { sqlite3_close(db) }

        // Standard iTunes backup Files table schema
        let createSQL = """
            CREATE TABLE IF NOT EXISTS Files (
                fileID TEXT PRIMARY KEY NOT NULL,
                domain TEXT,
                relativePath TEXT,
                flags INTEGER,
                file BLOB
            );
        """
        var errMsg: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, createSQL, nil, nil, &errMsg) == SQLITE_OK else {
            throw BackupError.sqliteExecFailed(String(cString: errMsg!))
        }

        let insertSQL = """
            INSERT OR REPLACE INTO Files (fileID, domain, relativePath, flags, file)
            VALUES (?, ?, ?, ?, ?);
        """

        for file in files {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else {
                throw BackupError.sqlitePrepFailed
            }
            defer { sqlite3_finalize(stmt) }

            let blob = buildFileBlob(for: file)
            let blobBytes = [UInt8](blob)

            sqlite3_bind_text(stmt, 1, file.fileID, -1, BackupManifestBuilder.SQLITE_TRANSIENT_FUNC)
            sqlite3_bind_text(stmt, 2, file.domain, -1, BackupManifestBuilder.SQLITE_TRANSIENT_FUNC)
            sqlite3_bind_text(stmt, 3, file.relativePath, -1, BackupManifestBuilder.SQLITE_TRANSIENT_FUNC)
            sqlite3_bind_int(stmt, 4, 1)  // flags: 1 = regular file
            sqlite3_bind_blob(stmt, 5, blobBytes, Int32(blobBytes.count), BackupManifestBuilder.SQLITE_TRANSIENT_FUNC)

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw BackupError.sqliteStepFailed
            }
        }
    }

    // SQLITE_TRANSIENT as a Swift function pointer
    private static let SQLITE_TRANSIENT_FUNC = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Builds the binary plist "file blob" stored in Manifest.db Files.file column.
    /// Encodes file metadata (mode, uid, gid, size, timestamps, protection class).
    private static func buildFileBlob(for file: BackupFile) -> Data {
        let now = Int(Date().timeIntervalSince1970)

        let metadata: NSDictionary = [
            "$version": 100000,
            "$archiver": "NSKeyedArchiver",
            "$top": ["root": ["CF$UID": 1]] as NSDictionary,
            "$objects": [
                "$null",
                [
                    "$class": ["CF$UID": 2] as NSDictionary,
                    "Mode":    UInt16(0o100644),  // -rw-r--r--
                    "Inode":   UInt64(0),
                    "UID":     UInt32(0),
                    "GID":     UInt32(0),
                    "MTime":   now,
                    "CTime":   now,
                    "BTime":   now,
                    "Size":    file.data.count,
                    "Flags":   UInt64(0),
                    "ProtectionClass": UInt32(0)
                ] as [String: Any],
                [
                    "$classname": "MBFile",
                    "$classes": ["MBFile", "NSObject"]
                ] as [String: Any]
            ] as [Any]
        ]

        return (try? PropertyListSerialization.data(
            fromPropertyList: metadata,
            format: .binary,
            options: 0
        )) ?? Data()
    }

    // MARK: - Manifest.plist

    private static func writeManifestPlist(to dir: URL) throws {
        let manifest: NSDictionary = [
            "BackupKeyBag":        Data(),
            "Version":             "10.0",
            "Date":                Date(),
            "IsEncrypted":         false,
            "WasPasscodeSet":      false,
            "SystemDomainsVersion": "20.0",
            "Lockdown": [
                "UniqueDeviceID":  "unknown",
                "ProductVersion":  "27.0",
                "ProductType":     "iPhone16,1",
                "SerialNumber":    "unknown",
                "DeviceName":      "iPhone"
            ] as NSDictionary
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: manifest, format: .binary, options: 0
        )
        try data.write(to: dir.appendingPathComponent("Manifest.plist"))
    }

    // MARK: - Info.plist

    private static func writeInfoPlist(to dir: URL) throws {
        let udid = UUID().uuidString.replacingOccurrences(of: "-", with: "").uppercased()
        let info: NSDictionary = [
            "Build Version":       "27A5241b",
            "Device Name":         "iPhone",
            "Display Name":        "iPhone",
            "GUID":                UUID().uuidString,
            "ICCID":               "",
            "IMEI":                "",
            "Last Backup Date":    Date(),
            "Product Name":        "iPhone OS",
            "Product Type":        "iPhone16,1",
            "Product Version":     "27.0",
            "Serial Number":       "unknown",
            "Target Identifier":   udid,
            "Target Type":         "Device",
            "Unique Identifier":   udid,
            "iTunes Files":        NSDictionary(),
            "iTunes Settings":     NSDictionary(),
            "iTunes Version":      "12.12.10.1"
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: info, format: .binary, options: 0
        )
        try data.write(to: dir.appendingPathComponent("Info.plist"))
    }

    // MARK: - Status.plist

    private static func writeStatusPlist(to dir: URL) throws {
        let status: NSDictionary = [
            "BackupState":   "new",
            "Date":          Date(),
            "IsFullBackup":  false,
            "SnapshotState": "finished",
            "UUID":          UUID().uuidString.uppercased(),
            "Version":       "3.3"
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: status, format: .binary, options: 0
        )
        try data.write(to: dir.appendingPathComponent("Status.plist"))
    }
}

enum BackupError: Error, LocalizedError {
    case sqliteOpenFailed
    case sqliteExecFailed(String)
    case sqlitePrepFailed
    case sqliteStepFailed

    var errorDescription: String? {
        switch self {
        case .sqliteOpenFailed:       return "Failed to open Manifest.db"
        case .sqliteExecFailed(let m): return "SQLite exec failed: \(m)"
        case .sqlitePrepFailed:       return "SQLite prepare failed"
        case .sqliteStepFailed:       return "SQLite step failed"
        }
    }
}
