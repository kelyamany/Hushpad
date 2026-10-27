import SwiftUI

/// The one big button. Idle: a red disc in a ring. Recording: the disc morphs into a rounded "stop" square
/// and the ring breathes. Used on iPhone, Watch and in the Mac HUD.
public struct RecordButton: View {
    public var isRecording: Bool
    public var diameter: CGFloat
    public var action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    public init(isRecording: Bool, diameter: CGFloat = 88, action: @escaping () -> Void) {
        self.isRecording = isRecording
        self.diameter = diameter
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(Theme.record.opacity(isRecording ? 0.35 : 0.25), lineWidth: diameter * 0.055)
                if isRecording && !reduceMotion {
                    Circle()
                        .stroke(Theme.record.opacity(0.5), lineWidth: diameter * 0.03)
                        .phaseAnimator([1.0, 1.18]) { ring, scale in
                            ring.scaleEffect(scale).opacity(2.2 - scale * 1.8)
                        } animation: { _ in .easeInOut(duration: 1.4) }
                }
                RoundedRectangle(cornerRadius: isRecording ? diameter * 0.1 : diameter * 0.5, style: .continuous)
                    .fill(Theme.recordGradient)
                    .frame(width: isRecording ? diameter * 0.38 : diameter * 0.76,
                           height: isRecording ? diameter * 0.38 : diameter * 0.76)
                    .shadow(color: Theme.record.opacity(0.35), radius: diameter * 0.08, y: diameter * 0.03)
            }
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
            .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(PressableStyle())
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: isRecording)
        .sensoryFeedback(isRecording ? .start : .stop, trigger: isRecording)
        .accessibilityLabel(isRecording ? "Stop recording" : "Start recording")
        .accessibilityAddTraits(.isButton)
    }
}

/// Subtle press-down scale used by custom buttons.
public struct PressableStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
