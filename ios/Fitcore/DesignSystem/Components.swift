import SwiftUI

struct FitcoreCard<Content: View>: View {
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background(.white, in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(FitcoreTheme.navy.opacity(0.07)))
    }
}

struct MockBadge: View {
    var body: some View {
        Label("MOCK · 示例演示", systemImage: "testtube.2")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .foregroundStyle(FitcoreTheme.navy)
            .background(FitcoreTheme.limeSoft, in: Capsule())
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 50)
            .foregroundStyle(.white)
            .background(FitcoreTheme.accent.opacity(configuration.isPressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: 16))
            .opacity(isEnabled ? 1 : 0.5)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct TrainingEventCard: View {
    let event: TrainingEvent

    var body: some View {
        FitcoreCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "dumbbell.fill").foregroundStyle(FitcoreTheme.accent)
                    Text(event.exercise).font(.headline)
                    Spacer()
                    Text("示例").font(.caption).foregroundStyle(FitcoreTheme.muted)
                }
                Text("\(event.weightKilograms.formatted()) kg  ·  \(event.repetitions) 次")
                    .font(.title3.weight(.bold)).foregroundStyle(FitcoreTheme.navy)
                Text(event.sourceText).font(.subheadline).foregroundStyle(FitcoreTheme.muted)
                Text(event.feeling).font(.caption).foregroundStyle(FitcoreTheme.accent)
            }
        }
    }
}

struct FitcorePageHeader: View {
    let eyebrow: String
    let title: String
    var detail: String = ""

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text(eyebrow).font(.system(size: 10, weight: .semibold)).tracking(1.4).foregroundStyle(FitcoreTheme.muted)
                Text(title).font(.system(size: 27, weight: .bold)).foregroundStyle(FitcoreTheme.ink)
            }
            Spacer(minLength: 8)
            if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(FitcoreTheme.muted) }
        }
        .padding(.vertical, 6)
    }
}

struct OutlineButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .frame(maxWidth: .infinity, minHeight: 43)
            .foregroundStyle(FitcoreTheme.navy)
            .background(FitcoreTheme.canvas.opacity(configuration.isPressed ? 1 : 0.45), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(FitcoreTheme.line))
            .opacity(isEnabled ? 1 : 0.4)
    }
}

struct RecorderArtwork: View {
    var isOutOfCase: Bool = false
    var showCase: Bool = true
    var active: Bool = false
    var size: CGFloat = 128
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if showCase {
                Image("RecorderCase").resizable().scaledToFit()
                    .frame(width: size, height: size)
                    .opacity(isOutOfCase ? 0.24 : 1)
                    .scaleEffect(isOutOfCase ? 0.92 : 1)
                    .offset(y: isOutOfCase ? size * 0.17 : 0)
            }
            if !showCase || isOutOfCase {
                Image("RecorderBean").resizable().scaledToFit()
                    .frame(width: size * 0.68, height: size * 0.78)
                    .rotationEffect(.degrees(isOutOfCase ? -12 : 0))
                    .offset(y: showCase ? -size * 0.18 : 0)
                    .shadow(color: FitcoreTheme.navy.opacity(0.15), radius: 10, y: 8)
                    .overlay(alignment: .top) {
                        Circle().fill(active ? FitcoreTheme.lime : FitcoreTheme.accent)
                            .frame(width: 5, height: 5)
                            .shadow(color: active ? FitcoreTheme.lime : .clear, radius: 6)
                            .offset(x: -6, y: showCase ? 6 : 21)
                    }
                    .transition(.opacity.combined(with: .offset(y: 12)))
            }
        }
        .frame(width: size, height: size + 18)
        .animation(reduceMotion ? nil : .spring(response: 0.6, dampingFraction: 0.72), value: isOutOfCase)
        .accessibilityHidden(true)
    }
}

struct TrainingWaveform: View {
    var active: Bool
    var color: Color = FitcoreTheme.accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let heights: [CGFloat] = [8, 15, 10, 20, 8, 17, 12, 22, 8, 15, 10, 20, 8, 16, 11, 19, 8, 14]

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.25, paused: !active || reduceMotion)) { context in
            HStack(spacing: 3) {
                ForEach(heights.indices, id: \.self) { index in
                    Capsule().fill(color.opacity(active ? 0.75 : 0.24))
                        .frame(width: 3, height: height(index, date: context.date))
                }
            }
            .frame(height: 28)
        }
        .accessibilityHidden(true)
    }

    private func height(_ index: Int, date: Date) -> CGFloat {
        guard active && !reduceMotion else { return heights[index] }
        return 6 + abs(sin(date.timeIntervalSinceReferenceDate * 3 + Double(index) * 0.85)) * heights[index]
    }
}
