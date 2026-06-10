import Foundation

/// Builds the GenerativeModels.plist payload for the BookRestore.
///
/// Target path on device:
///   /System/Library/FeatureFlags/Domain/GenerativeModels.plist
///
/// This plist controls Apple Intelligence / Siri AI feature flags.
/// We only modify EnhancedSiriWaitlist — all other known keys are preserved.
struct PlistPayloadBuilder {

    enum SiriWaitlistState {
        case enabled
        case disabled
    }

    /// Build the full GenerativeModels.plist as binary plist Data.
    ///
    /// - Parameter state: .enabled bypasses the waitlist, .disabled reverts.
    /// - Returns: Binary plist Data ready to be written to the backup.
    ///
    /// IMPORTANT: The key list below is based on iOS 26/macOS 27 research.
    /// If iOS 27 has additional keys, add them here to avoid clobbering them.
    /// To get the authoritative key list, SSH into a device that already has
    /// Siri AI access and run:
    ///   plutil -convert xml1 /System/Library/FeatureFlags/Domain/GenerativeModels.plist -o -
    static func build(state: SiriWaitlistState) -> Data {

        let waitlistEnabled = (state == .enabled)

        // Full known structure of GenerativeModels.plist.
        // Each top-level key maps to a dict with at minimum an "Enabled" bool.
        // Source: macOS 27 SIP bypass research + f1shy-dev Apple Intelligence gist.
        let dict: [String: Any] = [

            // === TARGET KEY — this is what we're toggling ===
            "EnhancedSiriWaitlist": [
                "Enabled": waitlistEnabled
            ],

            // === Preserved keys — do not remove these ===
            "Siri": [
                "Enabled": true
            ],
            "SiriNL": [
                "Enabled": true
            ],
            "TextComposer": [
                "Enabled": true
            ],
            "PrivateCloudCompute": [
                "Enabled": true
            ],
            "ImagePlayground": [
                "Enabled": true
            ],
            "WritingTools": [
                "Enabled": true
            ],
            "Summarization": [
                "Enabled": true
            ],
            "SmartReply": [
                "Enabled": true
            ],
            "PrioritizedNotifications": [
                "Enabled": true
            ],
            "ReducedInterruptions": [
                "Enabled": true
            ],
            "IntelligentSearch": [
                "Enabled": true
            ],
            "PhotosCleanup": [
                "Enabled": true
            ],
            "NaturalLanguageShortcuts": [
                "Enabled": true
            ]
            // Add any additional iOS 27-specific keys here as they are discovered.
        ]

        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: dict,
            format: .binary,   // iOS requires binary plist format
            options: 0
        ) else {
            // Should never fail with a valid dict
            fatalError("PlistPayloadBuilder: Failed to serialize plist")
        }

        return data
    }
}
