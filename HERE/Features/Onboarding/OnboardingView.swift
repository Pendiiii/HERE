import SwiftUI

struct OnboardingView: View {
    @Binding var isComplete: Bool
    @State private var page = 0

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                OnboardingPage(visual: .nearby, title: "Was passiert hier?", detail: "Sieh, was Menschen direkt um dich herum posten.").tag(0)
                OnboardingPage(visual: .ephemeral, title: "Nur jetzt. Nur hier.", detail: "Keine Follower. Keine Likes. Alles verschwindet.").tag(1)
                OnboardingPage(visual: .privacy, title: "Nähe, nicht Position.", detail: "Dein genauer Standort bleibt privat.").tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))

            Button(page == 2 ? "Los geht’s" : "Weiter") {
                if page < 2 { withAnimation(.snappy) { page += 1 } }
                else { isComplete = true }
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .buttonStyle(.borderedProminent)
            .clipShape(Capsule())
            .padding(24)
        }
        .sensoryFeedback(.selection, trigger: page)
        .background(Color(uiColor: .systemBackground))
    }
}

private struct OnboardingPage: View {
    let visual: OnboardingVisual
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 22) {
            AnimatedOnboardingVisual(kind: visual)
                .frame(height: 310)
            Text(title)
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)
            Text(detail)
                .font(.title3)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.horizontal, 30)
        .accessibilityElement(children: .combine)
    }
}

private enum OnboardingVisual {
    case nearby, ephemeral, privacy
}

private struct AnimatedOnboardingVisual: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let kind: OnboardingVisual

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
            let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            Group {
                switch kind {
                case .nearby: nearbyVisual(time)
                case .ephemeral: ephemeralVisual(time)
                case .privacy: privacyVisual(time)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func nearbyVisual(_ time: Double) -> some View {
        let wave = (sin(time * 1.8) + 1) / 2
        return ZStack {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .stroke(Color.hereAccent.opacity(0.24 - Double(index) * 0.055), lineWidth: 2)
                    .frame(width: 150 + CGFloat(index) * 54, height: 150 + CGFloat(index) * 54)
                    .scaleEffect(0.92 + wave * 0.08)
            }
            HEREWordmark(width: 230)
                .offset(y: sin(time * 1.8) * 5)
            SignalDot(symbol: "cup.and.saucer", color: .orange)
                .offset(x: -126, y: -82 + sin(time * 2.0) * 7)
            SignalDot(symbol: "car", color: .indigo)
                .offset(x: 126, y: 72 + sin(time * 1.7) * 7)
            SignalDot(symbol: "figure.2", color: .green)
                .offset(x: -112, y: 98 + sin(time * 2.2) * 6)
        }
    }

    private func ephemeralVisual(_ time: Double) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .fill(Color.hereAccent.opacity(0.08))
                .frame(width: 290, height: 255)
            VStack(spacing: 13) {
                TemporaryPost(symbol: "fork.knife", width: 184, phase: pulse(time, delay: 0.0))
                TemporaryPost(symbol: "questionmark", width: 226, phase: pulse(time, delay: 0.8))
                TemporaryPost(symbol: "ticket", width: 164, phase: pulse(time, delay: 1.6))
            }
            Image(systemName: "timer")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Color.hereAccent)
                .padding(13)
                .background(.thinMaterial, in: Circle())
                .offset(x: 130, y: -116)
                .rotationEffect(.degrees(sin(time * 2) * 7))
        }
    }

    private func privacyVisual(_ time: Double) -> some View {
        let wave = (sin(time * 1.7) + 1) / 2
        return ZStack {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.hereAccent.opacity(0.13 - Double(index) * 0.03))
                    .frame(width: 105 + CGFloat(index) * 68, height: 105 + CGFloat(index) * 68)
                    .scaleEffect(0.94 + wave * (0.035 + Double(index) * 0.012))
            }
            Circle()
                .fill(Color.hereAccent)
                .frame(width: 84, height: 84)
                .shadow(color: Color.hereAccent.opacity(0.3), radius: 22)
            Image(systemName: "location.fill")
                .font(.system(size: 31, weight: .bold))
                .foregroundStyle(.white)
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(14)
                .background(.regularMaterial, in: Circle())
                .shadow(color: .black.opacity(0.1), radius: 12, y: 6)
                .offset(x: 104, y: 92 + sin(time * 2) * 5)
        }
    }

    private func pulse(_ time: Double, delay: Double) -> Double {
        (sin((time - delay) * 1.7) + 1) / 2
    }
}

private struct SignalDot: View {
    let symbol: String
    let color: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 48, height: 48)
            .background(.regularMaterial, in: Circle())
            .shadow(color: .black.opacity(0.1), radius: 12, y: 5)
    }
}

private struct TemporaryPost: View {
    let symbol: String
    let width: CGFloat
    let phase: Double

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .frame(width: 24)
                .foregroundStyle(Color.hereAccent)
            Capsule().fill(.secondary.opacity(0.22)).frame(height: 9)
        }
        .padding(.horizontal, 16)
        .frame(width: width, height: 58)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .opacity(0.42 + phase * 0.58)
        .scaleEffect(0.96 + phase * 0.04)
        .offset(x: (phase - 0.5) * 8)
    }
}
