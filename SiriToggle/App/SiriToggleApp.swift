import SwiftUI

@main
struct SiriToggleApp: App {

    init() {
        // Attempt to start minimuxer tunnel early if pairing file already imported
        if let path = PairingFileManager.shared.pairingFilePath {
            Task.detached(priority: .userInitiated) {
                try? MinimuxerBridge.shared.start(pairingFilePath: path)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
    }
}
