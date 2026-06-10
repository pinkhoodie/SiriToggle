import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {

    @StateObject private var engine = BookRestoreEngine()
    @StateObject private var pairingManager = PairingFileManager.shared
    @State private var isEnabled = false
    @State private var showFilePicker = false
    @State private var showRebootAlert = false
    @State private var showInfoSheet = false

    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                colors: [Color(red: 0.05, green: 0.05, blue: 0.1), Color.black],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {

                // MARK: - Header
                VStack(spacing: 6) {
                    HStack {
                        Spacer()
                        Button {
                            showInfoSheet = true
                        } label: {
                            Image(systemName: "info.circle")
                                .foregroundColor(.gray)
                                .font(.system(size: 18))
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 16)

                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.purple, .blue],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .padding(.top, 8)

                    Text("SiriToggle")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundColor(.white)

                    Text("iOS 27 Siri AI Waitlist Bypass")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Color.gray)
                }
                .padding(.bottom, 36)

                // MARK: - Pairing File Card
                pairingFileCard
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)

                // MARK: - Toggle Card
                ToggleCardView(
                    isOn: $isEnabled,
                    disabled: !pairingManager.hasPairingFile
                        || engine.status == .restoring
                        || engine.status == .building
                )
                .padding(.horizontal, 24)
                .onChange(of: isEnabled) { newValue in
                    Task {
                        await engine.apply(state: newValue ? .enabled : .disabled)
                        if case .success = engine.status {
                            showRebootAlert = true
                        }
                        // If failed, revert toggle
                        if case .failed(_) = engine.status {
                            isEnabled = !newValue
                        }
                    }
                }

                // MARK: - Status + Progress
                VStack(spacing: 12) {
                    statusView
                        .padding(.top, 20)

                    if engine.status == .building || engine.status == .restoring {
                        ProgressView(value: engine.progress)
                            .tint(.purple)
                            .padding(.horizontal, 48)
                            .animation(.easeInOut, value: engine.progress)
                    }
                }

                Spacer()

                // MARK: - Footer note
                Text("Requires iOS 27 Beta · Developer Mode · Pairing File")
                    .font(.system(size: 10))
                    .foregroundColor(Color.gray.opacity(0.5))
                    .padding(.bottom, 24)
            }
        }
        // MARK: - File Picker
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                do {
                    try pairingManager.importPairingFile(from: url)
                } catch {
                    engine.setError(error.localizedDescription)
                }
            case .failure(let error):
                engine.setError(error.localizedDescription)
            }
        }
        // MARK: - Alerts
        .alert("Reboot Required", isPresented: $showRebootAlert) {
            Button("OK") {}
        } message: {
            Text("The change has been applied. Reboot your device to activate the new Siri AI.")
        }
        // MARK: - Info Sheet
        .sheet(isPresented: $showInfoSheet) {
            InfoSheetView()
        }
    }

    // MARK: - Pairing File Card

    @ViewBuilder
    private var pairingFileCard: some View {
        HStack(spacing: 12) {
            Image(systemName: pairingManager.hasPairingFile
                  ? "checkmark.circle.fill"
                  : "exclamationmark.circle.fill")
                .foregroundColor(pairingManager.hasPairingFile ? .green : .orange)
                .font(.system(size: 20))

            VStack(alignment: .leading, spacing: 2) {
                Text(pairingManager.hasPairingFile
                     ? "Pairing File Ready"
                     : "Pairing File Required")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                Text(pairingManager.hasPairingFile
                     ? "Device tunnel available"
                     : "Generate with jitterbugpair on Mac")
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
            }

            Spacer()

            Button {
                showFilePicker = true
            } label: {
                Text(pairingManager.hasPairingFile ? "Replace" : "Import")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        pairingManager.hasPairingFile
                        ? Color.gray.opacity(0.3)
                        : Color.orange.opacity(0.8)
                    )
                    .cornerRadius(8)
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.06))
        .cornerRadius(14)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(
                    pairingManager.hasPairingFile
                    ? Color.green.opacity(0.2)
                    : Color.orange.opacity(0.3),
                    lineWidth: 1
                )
        )
    }

    // MARK: - Status View

    @ViewBuilder
    private var statusView: some View {
        Group {
            switch engine.status {
            case .idle:
                Text(pairingManager.hasPairingFile
                     ? "Ready — use the toggle above"
                     : "Import your pairing file to begin")
                    .foregroundColor(.gray)
            case .building:
                Label("Building payload…", systemImage: "hammer.fill")
                    .foregroundColor(.yellow)
            case .restoring:
                Label("Applying via BookRestore…", systemImage: "arrow.clockwise.circle.fill")
                    .foregroundColor(.blue)
            case .success:
                Label("Applied — reboot to activate", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
            case .failed(let msg):
                VStack(spacing: 4) {
                    Label("Failed", systemImage: "xmark.circle.fill")
                        .foregroundColor(.red)
                    Text(msg)
                        .font(.system(size: 11))
                        .foregroundColor(Color.red.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            }
        }
        .font(.system(size: 13, weight: .medium))
        .animation(.easeInOut, value: engine.status == .idle)
    }
}
