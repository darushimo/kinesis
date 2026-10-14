import AppKit
import SwiftUI
import KinesisCore

/// Records a shortcut the way System Settings does: click, then press the keys.
/// It records a chord: hold the modifiers and press the key, in any order, and it saves
/// once every key is let go. Escape cancels and Delete clears. A modifier pressed and let
/// go on its own, such as right Option or fn, records just that modifier, for apps that
/// listen for a held key.
@MainActor
final class ShortcutCapture: ObservableObject {
    enum Outcome {
        case record(KeyShortcut)
        case clear
        case cancel
    }

    @Published private(set) var recording = false
    /// The keys pressed so far, drawn while recording.
    @Published private(set) var preview = ""
    private var monitor: Any?
    private var finish: ((Outcome) -> Void)?
    /// Modifiers down right now, and every modifier pressed since recording began.
    private var held: KeyShortcut.Modifiers = []
    private var peak: KeyShortcut.Modifiers = []
    private var lastModifierKey: UInt16?
    /// The ordinary key in the chord, and the ordinary keys still down.
    private var mainKey: (code: UInt16, name: String)?
    private var keysDown: Set<UInt16> = []
    /// Only one recorder listens at a time.
    private static weak var active: ShortcutCapture?

    func start(_ done: @escaping (Outcome) -> Void) {
        Self.active?.cancel()
        stop()
        Self.active = self
        finish = done
        held = []
        peak = []
        lastModifierKey = nil
        mainKey = nil
        keysDown = []
        preview = ""
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged], handler: { [weak self] event in
            guard let self, self.handle(event) else { return event }
            return nil
        })
    }

    func cancel() {
        guard recording else { return }
        complete(.cancel)
    }

    /// The chord as pressed so far, with fn left off keys that always carry it.
    private var chord: KeyShortcut.Modifiers {
        guard let mainKey, KeyShortcut.keysCarryingFunctionFlag.contains(mainKey.code) else { return peak }
        return peak.subtracting(.function)
    }

    /// Returns true when the key event belonged to the recording, so no one else gets it.
    private func handle(_ event: NSEvent) -> Bool {
        guard recording else { return false }
        // Keys Kinesis posts for a gesture are not the person typing.
        guard event.cgEvent?.getIntegerValueField(.eventSourceUserData) != MacShortcuts.shortcutEventTag else { return false }
        switch event.type {
        case .flagsChanged:
            let flags = Self.modifiers(event.modifierFlags)
            if !flags.subtracting(held).isEmpty, KeyShortcut.modifierKeys[event.keyCode] != nil {
                lastModifierKey = event.keyCode
            }
            // Only real modifier presses count, not the fn flag macOS adds to arrows and F-keys.
            peak.formUnion(flags)
            held = flags
        case .keyDown:
            guard !event.isARepeat else { return true }
            let plain = held.isEmpty && keysDown.isEmpty && mainKey == nil
            if plain && event.keyCode == 53 {
                complete(.cancel)
                return true
            }
            if plain && (event.keyCode == 51 || event.keyCode == 117) {
                complete(.clear)
                return true
            }
            keysDown.insert(event.keyCode)
            mainKey = (event.keyCode, Self.keyName(event))
        case .keyUp:
            keysDown.remove(event.keyCode)
        default:
            return false
        }
        updatePreview()
        finishIfReleased()
        return true
    }

    private func updatePreview() {
        let symbols = KeyShortcut.Modifiers.ordered.filter { chord.contains($0.modifier) }.map(\.symbol).joined()
        preview = symbols + (mainKey?.name ?? "")
    }

    /// Saves the chord once every key in it is up.
    private func finishIfReleased() {
        guard recording, held.isEmpty, keysDown.isEmpty else { return }
        if let mainKey {
            complete(.record(KeyShortcut(keyCode: mainKey.code, modifiers: chord, key: mainKey.name)))
        } else if let key = lastModifierKey {
            // Everything let go with no key in between: the modifier is the shortcut.
            let name = KeyShortcut.name(forKeyCode: key) ?? "key \(key)"
            complete(.record(KeyShortcut(keyCode: key, modifiers: peak, key: name)))
        }
    }

    private func complete(_ outcome: Outcome) {
        let done = finish
        stop()
        done?(outcome)
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        finish = nil
        recording = false
        preview = ""
        if Self.active === self { Self.active = nil }
    }

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> KeyShortcut.Modifiers {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        var modifiers: KeyShortcut.Modifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.function) { modifiers.insert(.function) }
        return modifiers
    }

    static func keyName(_ event: NSEvent) -> String {
        if let name = KeyShortcut.name(forKeyCode: event.keyCode) { return name }
        // The key's own character, as if no modifier were held: K, not ˚ for ⌥K.
        if let characters = event.characters(byApplyingModifiers: []), !characters.isEmpty {
            return characters.uppercased()
        }
        return "key \(event.keyCode)"
    }
}

/// A pill that shows a recorded shortcut. Click it and press keys to record a new one.
struct ShortcutRecorder: View {
    let shortcut: KeyShortcut?
    let record: (KeyShortcut?) -> Void
    var label = ""
    @StateObject private var capture = ShortcutCapture()
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var text: String {
        if capture.recording { return capture.preview.isEmpty ? "type a shortcut" : capture.preview + "…" }
        return shortcut?.display ?? "record shortcut"
    }

    var body: some View {
        Button {
            if capture.recording {
                capture.cancel()
            } else {
                capture.start { outcome in
                    switch outcome {
                    case .record(let recorded): record(recorded)
                    case .clear: record(nil)
                    case .cancel: break
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "keyboard").font(.system(size: 11))
                    .foregroundStyle(capture.recording ? KinesisStyle.accent : KinesisStyle.secondary)
                Text(text).font(KinesisType.label).lineLimit(1)
                    .foregroundStyle(capture.recording || shortcut == nil ? KinesisStyle.secondary : KinesisStyle.ink)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(PillSurface(fill: capture.recording ? KinesisStyle.chip : hovered ? KinesisStyle.trayHover : KinesisStyle.tray,
                                    raised: capture.recording || hovered))
            .overlay {
                if capture.recording { Capsule().strokeBorder(KinesisStyle.accent, lineWidth: 1.5) }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).fixedSize()
        .onHover { hovered = $0 }
        .onDisappear { capture.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in capture.cancel() }
        .animation(reduceMotion ? nil : KinesisMotion.settle, value: capture.recording)
        .accessibilityLabel(label)
        .accessibilityValue(capture.recording ? "recording" : shortcut?.display ?? "none")
        .accessibilityHint("Activate, then press the keys. Escape cancels, Delete clears.")
    }
}
