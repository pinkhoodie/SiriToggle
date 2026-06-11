import SwiftUI

struct ToggleCardView: View {

    @Binding var isOn: Bool
    var disabled: Bool = false

    var body: some View {
        HStack(spacing: 16) {

            // Icon
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(
                        isOn
                        ? LinearGradient(colors: [.purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
                        : LinearGradient(colors: [Color.gray.opacity(0.3), Color.gray.opacity(0.2)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .frame(width: 44, height: 44)

                Image(systemName: isOn ? "sparkles" : "sparkles")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(isOn ? .white : .gray)
            }

            // Text
            VStack(alignment: .leading, spacing: 4) {
                Text("Siri AI Waitlist Bypass")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(disabled ? .gray : .white)

                Text("EnhancedSiriWaitlist.Enabled → \(isOn ? "false" : "true")")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(isOn ? Color.purple.opacity(0.9) : Color.gray.opacity(0.7))
            }

            Spacer()

            // Toggle
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(.purple)
                .disabled(disabled)
                .opacity(disabled ? 0.5 : 1.0)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(
                            isOn
                            ? Color.purple.opacity(0.4)
                            : Color.white.opacity(0.08),
                            lineWidth: 1
                        )
                )
        )
        .animation(.easeInOut(duration: 0.2), value: isOn)
        .animation(.easeInOut(duration: 0.2), value: disabled)
    }
}
