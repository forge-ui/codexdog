import SwiftUI

struct WatchdogLogo: View {
    var size: CGFloat
    var showsBackground = true

    var body: some View {
        ZStack {
            if showsBackground {
                RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.12, green: 0.14, blue: 0.18), Color(red: 0.03, green: 0.42, blue: 0.36)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }

            ZStack {
                ForEach(0..<6, id: \.self) { index in
                    Capsule(style: .continuous)
                        .stroke(showsBackground ? Color.white.opacity(0.82) : Color.primary, lineWidth: max(1, size * 0.035))
                        .frame(width: size * 0.45, height: size * 0.22)
                        .offset(y: -size * 0.13)
                        .rotationEffect(.degrees(Double(index) * 60))
                }
            }
            .frame(width: size * 0.7, height: size * 0.7)

            Circle()
                .fill(showsBackground ? Color(red: 0.04, green: 0.48, blue: 0.40) : Color.clear)
                .frame(width: size * 0.43, height: size * 0.43)
                .overlay {
                    Image(systemName: "dog.fill")
                        .font(.system(size: size * 0.25, weight: .semibold))
                        .foregroundStyle(showsBackground ? Color.white : Color.primary)
                }
                .shadow(color: .black.opacity(0.22), radius: size * 0.05, y: size * 0.025)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("CodexRelay 看门狗")
    }
}
