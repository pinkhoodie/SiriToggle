import SwiftUI

struct InfoSheetView: View {

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    HStack {
                        Text("About SiriToggle")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(.white)
                        Spacer()
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.gray)
                                .font(.system(size: 22))
                        }
                    }

                    infoRow(
                        icon: "wrench.and.screwdriver.fill",
                        color: .purple,
                        title: "How it works",
                        body: "Uses BookRestore (the same technique as Nugget/misaka26) to write a modified GenerativeModels.plist to /System/Library/FeatureFlags/Domain/, setting EnhancedSiriWaitlist to enabled."
                    )

                    infoRow(
                        icon: "doc.fill",
                        color: .orange,
                        title: "Pairing File",
                        body: "Generate a .mobiledevicepairing file using jitterbugpair on your Mac. Run: ./jitterbugpair — it outputs a file you import here."
                    )

                    infoRow(
                        icon: "iphone.and.arrow.forward",
                        color: .blue,
                        title: "After applying",
                        body: "Reboot your device. Then go to Settings → Siri — the new Siri AI should be available without the waitlist."
                    )

                    infoRow(
                        icon: "exclamationmark.triangle.fill",
                        color: .yellow,
                        title: "Requirements",
                        body: "iOS 27 Beta 1 or later. Developer Mode enabled. iPhone 15 Pro or newer. BookRestore compatibility with iOS 27 is unconfirmed — you are testing this."
                    )

                    infoRow(
                        icon: "arrow.counterclockwise",
                        color: .green,
                        title: "To revert",
                        body: "Toggle OFF and reboot. This restores the default disabled state of EnhancedSiriWaitlist."
                    )

                    Divider().overlay(Color.gray.opacity(0.3))

                    VStack(alignment: .leading, spacing: 6) {
                        Text("References")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.gray)
                        Text("github.com/leminlimez/Nugget")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.blue)
                        Text("github.com/jkcoxson/minimuxer")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.blue)
                        Text("github.com/straight-tamago/misaka26")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.blue)
                    }

                    Spacer(minLength: 40)
                }
                .padding(24)
            }
        }
    }

    @ViewBuilder
    private func infoRow(icon: String, color: Color, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .foregroundColor(color)
                .font(.system(size: 18))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                Text(body)
                    .font(.system(size: 13))
                    .foregroundColor(.gray)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.05))
        .cornerRadius(12)
    }
}
