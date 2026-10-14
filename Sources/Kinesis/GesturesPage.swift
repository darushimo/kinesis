import SwiftUI
import KinesisCore

struct GesturesPage: View {
    @ObservedObject var model: BandModel
    @State private var family = "swipe"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Kinesis's own switches only show in developer mode, and the air cursor one only in dev builds.
    /// Only a pinch can hold a shortcut down, and a pinch's release can't be a switch.
    private func actions(for gesture: RecognizedGesture) -> [Choice<MacAction>] {
        var tapAction: String?
        if case .tap(let tap) = gesture { tapAction = tap.action }
        return MacAction.allCases.filter { action in
            if action == .holdShortcut { return tapAction == "hold" }
            guard action.isKinesisSwitch else { return true }
            guard tapAction != "holdrelease" else { return false }
            #if KINESIS_DEV
            return model.developerMode
            #else
            return model.developerMode && action != .toggleAirCursor
            #endif
        }.map { Choice($0, $0.title.lowercased()) }
    }

    /// A pinch's release does nothing of its own while the pinch is holding a shortcut.
    private func releaseLetsGo(_ finger: String) -> Bool { model.tapMappings[.hold(finger)] == .holdShortcut }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("little moves. your rules.").font(KinesisType.title).tracking(-1.2).reveal(0)
            PillTray(options: ["swipe", "tap", "pinch"].map { Choice($0, $0) }, selection: family,
                     select: { family = $0 }, label: "Gesture family").reveal(1)
            VStack(alignment: .leading, spacing: 7) {
                Text(family == "swipe" ? "a shortcut at your fingertips." : family == "tap" ? "a quick touch, once or twice." : "hold it, or hold it and turn.")
                    .font(KinesisType.headline).tracking(-0.4)
                Text(family == "swipe" ? "slide your thumb across your index finger in any direction." : family == "tap" ? "tap your thumb to your index or middle finger." : "hold your thumb on a finger. a finger can act when you pinch, or turn like a dial as you turn your wrist.")
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
                    ForEach(TapGesture.allCases.filter { !$0.isPinch }) { tap in
                        assignment(tap.label, symbol: tap.symbol, gesture: .tap(tap),
                                   trigger: fires[.tap(tap)] ?? 0,
                                   selection: model.tapMappings[tap] ?? .none) { model.tapMappings[tap] = $0 }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 28) {
                        ForEach(["index", "middle"], id: \.self) { finger in
                            pinchSection(finger, fires: fires)
                        }
                    }
                }
            }
            }
            // A new family's rows arrive the same way a page does.
            .reveal(3).id(family).transition(.asymmetric(insertion: .identity, removal: .opacity.animation(.easeOut(duration: 0.1))))
            Text(model.live ? "perform a gesture and its row lights up." : "connect your band to try them as you edit.")
                .font(KinesisType.micro).foregroundStyle(KinesisStyle.secondary).padding(.top, -10).reveal(4)
            Text(family == "swipe" ? "desktop actions use the Mac’s Control + arrow shortcuts. window and tab actions stay in the current app." : family == "tap" ? "single taps start unassigned." : "a pinch’s release fires when you let go. hold a shortcut to keep keys down for as long as you pinch, like a push-to-talk key. for pinch + turn, volume follows your audio output, including AirPods; brightness controls your Mac’s display, and external displays may not respond.")
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
                                                           : "click, hold the modifiers, press the key, then let go. esc cancels, delete clears.") {
                    ShortcutRecorder(shortcut: model.recordedShortcut(for: gesture),
                                     record: { model.setRecordedShortcut($0, for: gesture) },
                                     label: label + " shortcut")
                }
                .padding(.leading, 36)
                .transition(.opacity)
            }
        }
    }

    /// One finger on the pinch tab: whether its pinch acts or turns, and what it does.
    private func pinchSection(_ finger: String, fires: [RecognizedGesture: Int]) -> some View {
        let mode = model.pinchMode(for: finger)
        let hold = TapGesture.hold(finger), release = TapGesture.holdRelease(finger)
        return VStack(alignment: .leading, spacing: 2) {
            OpenRow(symbol: "hand.pinch", title: finger + " " + mode.title) {
                PillTray(options: PinchMode.allCases.map { Choice($0, $0.title) }, selection: mode,
                         select: { model.setPinchMode($0, for: finger) }, label: finger.capitalized + " finger pinch")
            }
            Group {
                if mode == .pinch {
                    assignment("Pinch", symbol: hold.symbol, gesture: .tap(hold), trigger: fires[.tap(hold)] ?? 0,
                               selection: model.tapMappings[hold] ?? .none) { model.tapMappings[hold] = $0 }
                    if releaseLetsGo(finger) {
                        row(symbol: release.symbol, title: "release", trigger: fires[.tap(release)] ?? 0) {
                            Text("lets go of the shortcut").font(KinesisType.label).foregroundStyle(KinesisStyle.secondary)
                        }
                    } else {
                        assignment("Release", symbol: release.symbol, gesture: .tap(release), trigger: fires[.tap(release)] ?? 0,
                                   selection: model.tapMappings[release] ?? .none) { model.tapMappings[release] = $0 }
                    }
                } else {
                    row(symbol: "dial.low", title: "turn", held: model.dialEngaged && model.live && model.dialFinger == finger) {
                        PillMenu(options: DialTarget.allCases.map { Choice($0, $0.title.lowercased()) },
                                 selection: model.turnTarget(for: finger), select: { model.setTurnTarget($0, for: finger) },
                                 label: finger.capitalized + " dial controls")
                    }
                    let sensitivity = model.turnSensitivity(for: finger)
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("sensitivity").font(KinesisType.body)
                            Spacer()
                            Text(sensitivity.formatted(.number.precision(.fractionLength(2))) + "×")
                                .font(KinesisType.label).monospacedDigit().contentTransition(.numericText())
                                .animation(KinesisMotion.settle, value: sensitivity)
                        }
                        PillSlider(value: Binding(get: { model.turnSensitivity(for: finger) },
                                                  set: { model.setTurnSensitivity($0, for: finger) }),
                                   range: 0.5...4, step: 0.25, label: finger.capitalized + " dial sensitivity")
                        HStack {
                            Text("more precise")
                            Spacer()
                            Text("less movement")
                        }.font(KinesisType.micro).foregroundStyle(KinesisStyle.secondary)
                    }.padding(.top, 10).padding(.bottom, 6)
                }
            }
            .padding(.leading, 36)
        }
    }

    private func row<Control: View>(symbol: String, title: String, trigger: Int = 0, held: Bool = false,
                                    @ViewBuilder control: @escaping () -> Control) -> some View {
        Flash(trigger: trigger, held: held) { glow in
            OpenRow(symbol: symbol, title: title, glow: glow) { control() }
        }
    }
}
