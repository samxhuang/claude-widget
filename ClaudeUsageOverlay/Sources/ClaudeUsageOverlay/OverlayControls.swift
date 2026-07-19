import SwiftUI
import AppKit

/// Custom-drawn iOS-Settings-style switch, replacing SwiftUI's native
/// `Toggle(...).toggleStyle(.switch)`. User-reported bug this exists to fix:
/// `.tint(.green)` does not reliably render on the `.mini` `.switch` toggle
/// style on this macOS build — the track stayed gray even when `isOn` was
/// true (screenshots showed a green-tinted knob but a gray track). Drawing
/// the capsule track + knob ourselves sidesteps whatever's swallowing the
/// tint in AppKit's bridged NSSwitch and guarantees the saturated
/// on/off colors this widget actually wants.
///
/// Reusable across both toggle kinds in OverlayView's session rows (CLI
/// auto-resume: green; Cowork arm: red) — only the tint and bound state
/// differ per call site.
struct CompactSwitch: View {
    var isOn: Bool
    var tint: Color
    var action: () -> Void

    private let width: CGFloat = 26
    private let height: CGFloat = 16
    private let knobDiameter: CGFloat = 13
    private let inset: CGFloat = 1.5

    var body: some View {
        Button(action: action) {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? tint : Color.white.opacity(0.25))
                Circle()
                    .fill(Color.white)
                    .frame(width: knobDiameter, height: knobDiameter)
                    .padding(.horizontal, inset)
            }
            .frame(width: width, height: height)
            // ZStack's alignment is itself an animatable layout property in
            // SwiftUI — flipping between .leading/.trailing on state change
            // drives the knob's slide, no manual offset math needed.
            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isOn)
        }
        .buttonStyle(.plain)
        // Button already draws the whole capsule as its label, so the
        // capsule itself is the tap target — no separate contentShape
        // needed, but Capsule() as a Shape is hit-testable across its whole
        // bounding frame already since it's `.fill`ed (not stroked).
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

/// Unified running/needs-input/idle status indicator for session rows
/// (item: Claude-app-style status dots). Replaces the previous plain,
/// same-weight colored dot for every state with a treatment where each
/// state reads differently at a glance:
/// - running: a green dot that visibly pulses (see PulsingDot below) — the
///   animation itself is the "this is alive right now" signal.
/// - needsInput: a solid, slightly larger amber dot, no animation — it
///   should pop without competing with the pulsing running dot for
///   attention.
/// - idle/done (including `nil`, i.e. a state.json entry written before
///   `work_status` existed): no dot at all. A `Color.clear` placeholder of
///   the same footprint as the amber dot keeps the row's leading column
///   from jumping around as rows transition between states.
struct StatusIndicator: View {
    var workStatus: SessionWorkStatus?

    private var resolved: SessionWorkStatus { workStatus ?? .idle }

    var body: some View {
        Group {
            switch resolved {
            case .running:
                PulsingDot(color: Color(nsColor: .systemGreen), size: 6)
            case .needsInput:
                Circle()
                    .fill(Color(nsColor: .systemOrange))
                    .frame(width: 8, height: 8)
            case .idle:
                Color.clear.frame(width: 8, height: 8)
            }
        }
        .help(resolved.label)
    }
}

/// A dot that continuously fades between full opacity and ~30% on a
/// ~0.9s ease-in-out cycle, forever — the "alive/running right now" signal
/// for StatusIndicator above.
///
/// Mechanism (this is the part that's easy to get wrong and have silently
/// do nothing): the animation is NOT attached as an implicit `.animation`
/// modifier keyed off some externally-driven value — there is no such
/// value here that changes on its own. Instead, `onAppear` explicitly
/// kicks off a `withAnimation(...repeatForever...)` block that mutates a
/// local `@State` (`pulseDown`), which is what actually starts the
/// perpetually-repeating animation. Because the state lives in `@State`
/// (not read from the model), it's tied to this view's identity in the
/// SwiftUI view tree, not to the `SessionEntry`/`CloudSessionEntry` value
/// passed in from outside:
/// - When OverlayView's 5s poll refreshes `combinedSessionRows` and a row's
///   *value* changes (e.g. a new `lastActivityAt`), SwiftUI diffs the
///   ForEach by the row's stable `id` (see CombinedSessionRow.id) and
///   re-renders this same view in place — `onAppear` does NOT fire again,
///   the existing animation just keeps looping uninterrupted.
/// - Only when a row's `id` actually disappears and a new one appears
///   (e.g. a session transitions status and gets re-sorted to a different
///   position, or a genuinely new session shows up) does SwiftUI tear down
///   the old PulsingDot and mount a fresh one, whose `onAppear` starts the
///   loop cleanly from `pulseDown = false` — never a frozen mid-fade dot
///   left over from a torn-down animation.
struct PulsingDot: View {
    var color: Color
    var size: CGFloat

    @State private var pulseDown = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .opacity(pulseDown ? 0.3 : 1.0)
            .onAppear {
                pulseDown = false
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    pulseDown = true
                }
            }
    }
}
