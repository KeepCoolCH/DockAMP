import SwiftUI

struct HoldToRevealPasswordField: View {
    let placeholder: String
    @Binding var text: String

    @State private var isRevealing = false

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if isRevealing {
                    TextField(placeholder, text: $text)
                } else {
                    SecureField(placeholder, text: $text)
                }
            }
            .textFieldStyle(.roundedBorder)

            Image(systemName: isRevealing ? "eye.fill" : "eye")
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            isRevealing = true
                        }
                        .onEnded { _ in
                            isRevealing = false
                        }
                )
                .help("Press and hold to reveal")
        }
        .onDisappear {
            isRevealing = false
        }
    }
}
