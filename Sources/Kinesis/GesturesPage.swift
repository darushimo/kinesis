import SwiftUI
import KinesisCore

struct GesturesPage: View {
    @ObservedObject var model: BandModel
    @State private var family = "swipe"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Kinesis's own switches only show in developer mode, and the air cursor one only in dev builds.
    /// Only a hold can hold a shortcut down, and a hold's release can't be a switch.
    private func actions(for gesture: RecognizedGesture) -> [Choice<MacAction>] {
        MacAction.allCases.filter { action in
            if action == .holdShortcut { return gesture == .tap(.middleHold) }
            guard action.isKinesisSwitch else { return true }
            guard gesture != .tap(.middleHoldRelease) else { return false }
            #if KINESIS_DEV
            return model.developerMode
            #else
            return model.developerMode && action != .toggleAirCursor
            #endif
        }.map { Choice($0, $0.title.lowercased()) }
    }

    /// The hold's release does nothing of its own while the hold is holding a shortcut.
    private var releaseLetsGo: Bool { model.tapMappings[.middleHold] == .holdShortcut }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("little moves. your rules.").font(KinesisType.title).tracking(-1.2).reveal(0)
            PillTray(options: ["swipe", "tap", "turn"].map { Choice($0, $0) }, selection: family,
                     select: { family = $0 }, label: "Gesture family").reveal(1)
            VStack(alignment: .leading, spacing: 7) {
                Text(family == "swipe" ? "a shortcut at your fingertips." : family == "tap" ? "taps, a hold, and its release." : "turn it just a little.")
                    .font(KinesisType.headline).tracking(-0.4)
                Text(family == "swipe" ? "slide your thumb across your index finger in any direction." : family == "tap" ? "tap your thumb to your index or middle finger, or hold it on the middle one." : "pinch thumb and index, then turn your wrist. release to reset.")
                    .font(KinesisType.caption).foregroundStyle(KinesisStyle.secondary)
            }.reveal(2)
            GestureLight(model: model) { fires in
            VStack(spacing: 2) {
                if family == "swipe" {
                    ForEach(SwipeDirection.allCases) { direction in
                        assignment(direction.label, symbol: direction.symbol, gesture: .swipe(direction),
                                   trigger: fires[.swipe(direction)] ?? 0,
                                   selection: model.mappings[direction] ?? .none) { model.mappings[direction] = $0 }
                    }
                } else if family == "tap" {
                    ForEach(TapGesture.allCases) { tap in
                        if tap == .middleHoldRelease && releaseLetsGo {
                            row(symbol: tap.symbol, title: tap.label.lowercased(), trigger: fires[.tap(tap)] ?? 0) {
                                Text("lets go of the shortcut").font(KinesisType.label).foregroundStyle(KinesisStyle.secondary)
                            }
                        } else {
                            assignment(tap.label, symbol: tap.symbol, gesture: .tap(tap),
                                       trigger: fires[.tap(tap)] ?? 0,
                                       selection: model.tapMappings[tap] ?? .none) { model.tapMappings[tap] = $0 }
                        }
                    }
                } else {
                    row(symbol: "dial.low", title: "pinch + turn", held: model.dialEngaged && model.live) {
                        PillMenu(options: DialTarget.allCases.map { Choice($0, $0.title.lowercased()) },
                                 selection: model.dialTarget, select: { model.dialTarget = $0 }, label: "Dial controls")
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("sensitivity").font(KinesisType.body)
                            Spacer()
                            Text(model.dialSensitivity.formatted(.number.precision(.fractionLength(2))) + "×")
                                .font(KinesisType.label).monospacedDigit().contentTransition(.numericText())
                                .animation(KinesisMotion.settle, value: model.dialSensitivity)
                        }
                        PillSlider(value: $model.dialSensitivity, range: 0.5...4, step: 0.25, label: "Dial sensitivity")
                        HStack {
                            Text("more precise")
                            Spacer()
                            Text("less movement")
                        }.font(KinesisType.micro).foregroundStyle(KinesisStyle.secondary)
                    }.padding(.top, 18)
                }
            }
            }
            // A new family's rows arrive the same way a page does.
            .reveal(3).id(family).transition(.asymmetric(insertion: .identity, removal: .opacity.animation(.easeOut(duration: 0.1))))
            Text(model.live ? "perform a gesture and its row lights up." : "connect your band to try them as you edit.")
                .font(KinesisType.micro).foregroundStyle(KinesisStyle.secondary).padding(.top, -10).reveal(4)
            Text(family == "swipe" ? "desktop actions use the Mac’s Control + arrow shortcuts. window and tab actions stay in the current app." : family == "tap" ? "single taps and the hold start unassigned. holding the index finger is the dial, so only the middle finger has a hold. its release fires when you let go after a hold. hold a shortcut to keep keys down for as long as you pinch, like a push-to-talk key." : "volume follows your audio output, including AirPods. brightness controls your Mac’s display; external displays may not respond. pinch again after changing settings.")
                .font(KinesisType.caption).foregroundStyle(KinesisStyle.secondary).lineSpacing(4).reveal(5)
        }
        .animation(reduceMotion ? nil : KinesisMotion.settle, value: family)
    }

    private func assignment(_ label: String, symbol: String, gesture: RecognizedGesture, trigger: Int, selection: MacAction,
                            select: @escaping (MacAction) -> Void) -> some View {
        VStack(spacing: 2) {
            row(symbol: symbol, title: label.lowercased(), trigger: trigger) {
                PillMenu(options: actions(for: gesture), selection: selection, select: select, label: label)
            }
            if selection.usesRecordedShortcut {
                // The keys sit under the gesture, as in System Settings: click, then press them.
                OpenRow(title: "shortcut",
                        detail: selection == .holdShortcut ? "pressed when the hold starts, let go when you release."
                                                           : "click, then press the keys. esc cancels, delete clears.") {
                    ShortcutRecorder(shortcut: model.recordedShortcut(for: gesture),
                                     record: { model.setRecordedShortcut($0, for: gesture) },
                                     label: label + " shortcut")
                }
                .padding(.leading, 36)
                .transition(.opacity)
            }
        }
    }

    private func row<Control: View>(symbol: String, title: String, trigger: Int = 0, held: Bool = false,
                                    @ViewBuilder control: @escaping () -> Control) -> some View {
        Flash(trigger: trigger, held: held) { glow in
            OpenRow(symbol: symbol, title: title, glow: glow) { control() }
        }
    }
}
