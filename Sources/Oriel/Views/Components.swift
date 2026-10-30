import OrielCore
import SwiftUI

/// A rounded, colored tile with the guest's symbol, so each system is recognizable at a glance.
struct GuestOSBadge: View {
    let guestOS: GuestOS
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: guestOS.symbolName)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(guestOS.badgeGradient, in: .rect(cornerRadius: size * 0.26, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: size * 0.04, y: size * 0.02)
            .accessibilityHidden(true)
    }
}

extension GuestOS {
    var badgeGradient: LinearGradient {
        let colors: [Color] = switch self {
        case .macOS: [Color(red: 0.42, green: 0.45, blue: 0.52), Color(red: 0.17, green: 0.18, blue: 0.22)]
        case .windows: [Color(red: 0.25, green: 0.56, blue: 0.98), Color(red: 0.11, green: 0.33, blue: 0.85)]
        case .linux: [Color(red: 0.98, green: 0.65, blue: 0.16), Color(red: 0.90, green: 0.36, blue: 0.07)]
        }
        return LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
    }
}

/// Human-readable machine state, shared by the sidebar, detail and machine windows.
struct StateLabel: View {
    let state: VMSession.State
    let hasSavedState: Bool

    var body: some View {
        switch state {
        case .stopped: hasSavedState ? Text("Suspended") : Text("Stopped")
        case .starting: Text("Starting…")
        case .running: Text("Running")
        case .paused: Text("Paused")
        case .suspending: Text("Suspending…")
        case .stopping: Text("Shutting down…")
        case .failed: Text("Error")
        }
    }
}

/// The state label with a colored dot in front. The text carries the meaning; the dot only speeds up scanning.
struct StatusBadge: View {
    let state: VMSession.State
    let hasSavedState: Bool

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            StateLabel(state: state, hasSavedState: hasSavedState)
        }
    }

    private var color: Color {
        switch state {
        case .running: .green
        case .starting, .suspending, .stopping, .paused: .orange
        case .failed: .red
        case .stopped: hasSavedState ? .indigo : .secondary.opacity(0.5)
        }
    }
}

/// A card-style button used for picking a guest system. Lifts and picks up the accent color on hover.
struct ChoiceCardStyle: ButtonStyle {
    var cornerRadius: CGFloat = 14

    func makeBody(configuration: Configuration) -> some View {
        ChoiceCard(configuration: configuration, cornerRadius: cornerRadius)
    }

    private struct ChoiceCard: View {
        let configuration: Configuration
        let cornerRadius: CGFloat
        @State private var isHovered = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            configuration.label
                .contentShape(shape)
                .background(Color(nsColor: .controlBackgroundColor), in: shape)
                .overlay {
                    shape.strokeBorder(isHovered ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator), lineWidth: isHovered ? 1.5 : 1)
                }
                .shadow(color: .black.opacity(isHovered ? 0.10 : 0.04), radius: isHovered ? 10 : 3, y: isHovered ? 4 : 1)
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .onHover { isHovered = $0 }
                .animation(.easeOut(duration: 0.15), value: isHovered)
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
        }
    }
}

/// A file the user picks, shown by name with a Choose button on the same row.
struct FileRow: View {
    let title: LocalizedStringKey
    let url: URL?
    let choose: () -> Void

    var body: some View {
        LabeledContent(title) {
            HStack {
                Text(url?.lastPathComponent ?? String(localized: "None selected"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(url == nil ? .secondary : .primary)
                Button("Choose…", action: choose)
            }
        }
    }
}

/// A whole-number count with the value beside the stepper arrows.
struct CountStepper: View {
    let title: LocalizedStringKey
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        LabeledContent(title) {
            Stepper(value: $value, in: range) {
                Text(value, format: .number)
                    .monospacedDigit()
            }
        }
    }
}

/// A byte size picked in whole gibibytes. Shown in binary units, so 64 GiB reads "64 GB", the number the user chose.
struct SizeSlider: View {
    let title: LocalizedStringKey
    @Binding var size: UInt64
    let range: ClosedRange<UInt64>
    var step: UInt64 = 1

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 12) {
                // No `step:` on the slider itself: on macOS that draws a tick for every step.
                Slider(
                    value: Binding(
                        get: { Double(size / .gibibyte) },
                        set: { size = UInt64(($0 / Double(step)).rounded()) * step * .gibibyte }
                    ),
                    in: Double(range.lowerBound / .gibibyte)...Double(range.upperBound / .gibibyte)
                )
                .frame(minWidth: 160)
                Text(size.formatted(.byteCount(style: .memory)))
                    .monospacedDigit()
                    .frame(minWidth: 60, alignment: .trailing)
            }
        }
    }
}
