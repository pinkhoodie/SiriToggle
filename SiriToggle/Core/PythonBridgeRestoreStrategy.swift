import Foundation

// MARK: - Python Bridge Restore Strategy

/// Restore strategy that shells out to pymobiledevice3 via a Python script.
///
/// This requires Python 3 and pymobiledevice3 to be installed:
///   pip install pymobiledevice3
///
/// The Python script is bundled at SiriToggle/Python/restore_via_python.py
/// and is executed as a subprocess. Progress and status are communicated
/// via JSON lines on stdout.
///
/// This is the easiest strategy to set up for development but requires
/// Python to be available at runtime. Best used on macOS with Homebrew Python.
struct PythonBridgeRestoreStrategy: RestoreStrategyProtocol {

    static var displayName: String { "Python Bridge" }
    static var description: String {
        "Shells out to pymobiledevice3 (the same library Nugget uses). "
        + "Requires Python 3 and: pip install pymobiledevice3. "
        + "Good fallback for development on macOS. Not suitable for App Store distribution."
    }
    static var requiresLibIMD: Bool { false }
    static var requiresPython: Bool { true }
    static var worksOnDevice: Bool { false }

    /// Path to the bundled Python script.
    private var scriptPath: String {
        // Look in the app bundle first, then fallback to a relative path
        if let bundlePath = Bundle.main.path(forResource: "restore_via_python", ofType: "py", inDirectory: "Python") {
            return bundlePath
        }
        // Fallback: assume script is in the same directory as the executable
        let executableDir = (Bundle.main.executablePath as NSString?)?.deletingLastPathComponent ?? "/tmp"
        return (executableDir as NSString).appendingPathComponent("restore_via_python.py")
    }

    /// Python 3 executable name.
    private let pythonExecutable = "python3"

    func restore(backupDir: URL, progress: @escaping (Double) -> Void) async throws {
        guard FileManager.default.fileExists(atPath: backupDir.path) else {
            throw RestoreError.backupDirNotFound
        }

        // Verify Python is available
        guard try await pythonAvailable() else {
            throw RestoreError.pythonNotFound
        }

        // Verify the script exists
        guard FileManager.default.fileExists(atPath: scriptPath) else {
            throw RestoreError.notAvailable("Python script not found at \(scriptPath). Make sure restore_via_python.py is bundled.")
        }

        try await runPythonScript(backupDir: backupDir, progress: progress)
    }

    // MARK: - Python Availability Check

    /// Check if Python 3 is installed and pymobiledevice3 is available.
    private func pythonAvailable() async throws -> Bool {
        #if os(macOS)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [pythonExecutable, "-c", "import pymobiledevice3; print('ok')"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return process.terminationStatus == 0 && output.contains("ok")
        #else
        return false
        #endif
    }

    // MARK: - Run Python Script

    /// Execute the Python restore script and parse its JSON line output.
    private func runPythonScript(backupDir: URL, progress: @escaping (Double) -> Void) async throws {
        #if os(macOS)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [pythonExecutable, scriptPath, backupDir.path]

        // Create pipes for stdout and stderr
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Set up async reading of stdout
        let fileHandle = stdoutPipe.fileHandleForReading

        try process.run()

        // Read output line by line
        var lastProgress: Double = 0.70
        var completionStatus: Bool? = nil
        var errorMessage: String? = nil

        // Use a continuation to bridge the delegate-based reading to async
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var buffer = Data()

            fileHandle.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }

                buffer.append(data)

                // Process complete lines
                while let newlineRange = buffer.range(of: Data([0x0A])) { // '\n'
                    let lineData = buffer.subdata(in: 0..<newlineRange.lowerBound)
                    buffer.removeSubrange(0..<newlineRange.upperBound)

                    if let line = String(data: lineData, encoding: .utf8)?.trimmingCharacters(in: .whitespaces),
                       !line.isEmpty,
                       let jsonData = line.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {

                        self.handleJSONMessage(json, lastProgress: &lastProgress, progress: progress, completionStatus: &completionStatus, errorMessage: &errorMessage)
                    }
                }
            }

            // Wait for process to complete on a background queue
            DispatchQueue.global(qos: .userInitiated).async {
                process.waitUntilExit()

                // Clean up
                fileHandle.readabilityHandler = nil

                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrOutput = String(data: stderrData, encoding: .utf8) ?? ""

                DispatchQueue.main.async {
                    let exitCode = process.terminationStatus

                    if let errorMsg = errorMessage {
                        continuation.resume(throwing: RestoreError.pythonScriptFailed(errorMsg))
                        return
                    }

                    if exitCode == 0 || completionStatus == true {
                        continuation.resume()
                    } else if exitCode == 2 {
                        continuation.resume(throwing: RestoreError.pythonNotFound)
                    } else if exitCode == 3 {
                        continuation.resume(throwing: RestoreError.connectionFailed("Device not connected or not paired. \(stderrOutput)"))
                    } else if exitCode == 4 {
                        continuation.resume(throwing: RestoreError.restoreRequestRejected("Find My must be disabled in Settings."))
                    } else if exitCode == 5 {
                        continuation.resume(throwing: RestoreError.restoreRequestRejected("Restore failed. \(stderrOutput)"))
                    } else {
                        continuation.resume(throwing: RestoreError.pythonScriptFailed("Python script exited with code \(exitCode). \(stderrOutput)"))
                    }
                }
            }
        }
        #else
        throw RestoreError.pythonNotFound
        #endif
    }

    /// Parse a JSON message from the Python script.
    private func handleJSONMessage(
        _ json: [String: Any],
        lastProgress: inout Double,
        progress: @escaping (Double) -> Void,
        completionStatus: inout Bool?,
        errorMessage: inout String?
    ) {
        guard let type = json["type"] as? String else { return }

        switch type {
        case "progress":
            if let value = json["value"] as? Double {
                // Map Python's 0.0-1.0 to our progress range (0.70-0.95)
                let mappedProgress = 0.70 + (value * 0.25)
                lastProgress = max(lastProgress, mappedProgress)
                progress(lastProgress)
            }

        case "status":
            if let message = json["message"] as? String {
                // Status messages can be logged or shown in UI
                print("[PythonBridge] \(message)")
            }

        case "complete":
            if let success = json["success"] as? Bool {
                completionStatus = success
            }

        case "error":
            if let message = json["message"] as? String {
                errorMessage = message
            }

        default:
            break
        }
    }
}
