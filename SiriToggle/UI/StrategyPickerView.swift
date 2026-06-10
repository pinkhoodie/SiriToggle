import SwiftUI

/// Strategy selector sheet that lets the user choose which mobilebackup2
/// implementation to use for the restore operation.
struct StrategyPickerView: View {

    @Environment(\.dismiss) private var dismiss
    @ObservedObject var engine: BookRestoreEngine

    var body: some View {
        NavigationView {
            List {
                // MARK: - Current Selection Header
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "gearshape.2.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(.purple)

                        Text("Restore Strategy")
                            .font(.system(size: 20, weight: .bold))

                        Text("Choose how the mobilebackup2 protocol is implemented. Each option has different requirements and trade-offs.")
                            .font(.system(size: 13))
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }

                // MARK: - Strategy Options
                Section(header: Text("Available Strategies")) {
                    ForEach(RestoreStrategy.allCases) { strategy in
                        strategyRow(
                            strategy: strategy,
                            isSelected: engine.selectedStrategy == strategy
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                engine.selectedStrategy = strategy
                            }
                        }
                    }
                }

                // MARK: - Troubleshooting
                Section(header: Text("Troubleshooting")) {
                    troubleshootRow(
                        icon: "xmark.circle.fill",
                        color: .red,
                        title: "'Not Available' error?",
                        body: "The strategy's requirements aren't met. Check the description above — you may need to install Python, link a library, or select a different strategy."
                    )

                    troubleshootRow(
                        icon: "arrow.triangle.2.circlepath",
                        color: .blue,
                        title: "Automatic fallback",
                        body: "If your selected strategy fails, the engine automatically tries the other strategies in order. You don't need to manually switch unless you want to."
                    )

                    troubleshootRow(
                        icon: "swift",
                        color: .orange,
                        title: "Recommended for iOS",
                        body: "Pure Swift is the only strategy that works on-device without external dependencies. Use it for iOS builds."
                    )

                    troubleshootRow(
                        icon: "terminal.fill",
                        color: .green,
                        title: "Recommended for macOS dev",
                        body: "Python Bridge is the easiest to set up for development — just run: pip install pymobiledevice3"
                    )
                }
            }
            .listStyle(InsetGroupedListStyle())
            .navigationBarHidden(true)
            .overlay(
                // Close button
                VStack {
                    HStack {
                        Spacer()
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 26))
                                .foregroundColor(.gray)
                        }
                        .padding(.top, 12)
                        .padding(.trailing, 16)
                    }
                    Spacer()
                }
            )
        }
    }

    // MARK: - Strategy Row

    @ViewBuilder
    private func strategyRow(strategy: RestoreStrategy, isSelected: Bool) -> some View {
        HStack(spacing: 14) {
            // Icon
            ZStack {
                Circle()
                    .fill(strategySwiftColor(strategy).opacity(0.15))
                    .frame(width: 36, height: 36)

                Image(systemName: strategy.icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(strategySwiftColor(strategy))
            }

            // Info
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(strategy.displayName)
                        .font(.system(size: 15, weight: .semibold))

                    if isSelected {
                        Text("Active")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.purple)
                            .cornerRadius(4)
                    }
                }

                Text(strategy.description)
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                // Requirement badges
                HStack(spacing: 6) {
                    if strategy == .libIMD {
                        requirementBadge(text: "C Library", color: .blue)
                    }
                    if strategy == .pureSwift {
                        requirementBadge(text: "No deps", color: .green)
                        requirementBadge(text: "iOS OK", color: .orange)
                    }
                    if strategy == .pythonBridge {
                        requirementBadge(text: "Python 3", color: .green)
                        requirementBadge(text: "pymobiledevice3", color: .green)
                    }
                }
                .padding(.top, 2)
            }

            Spacer()

            // Selection indicator
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.purple)
                    .font(.system(size: 22))
            } else {
                Circle()
                    .stroke(Color.gray.opacity(0.3), lineWidth: 1.5)
                    .frame(width: 22, height: 22)
            }
        }
        .padding(.vertical, 6)
        .background(isSelected ? Color.purple.opacity(0.05) : Color.clear)
    }

    // MARK: - Requirement Badge

    @ViewBuilder
    private func requirementBadge(text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .cornerRadius(4)
    }

    // MARK: - Troubleshoot Row

    @ViewBuilder
    private func troubleshootRow(icon: String, color: Color, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(color)
                .font(.system(size: 16))
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(body)
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Color Helper

    private func strategySwiftColor(_ strategy: RestoreStrategy) -> Color {
        switch strategy {
        case .libIMD:       return .blue
        case .pureSwift:    return .orange
        case .pythonBridge: return .green
        }
    }
}

// MARK: - Preview

struct StrategyPickerView_Previews: PreviewProvider {
    @MainActor
    static var previews: some View {
        StrategyPickerView(engine: BookRestoreEngine())
            .preferredColorScheme(.dark)
    }
}
