import AppKit
import SwiftUI
import KinesisCore

/// Records a shortcut the way System Settings does: click, then press the keys.
/// Escape cancels and Delete clears. A modifier pressed and let go on its own, such as
/// right Option or fn, records just that modifier, for apps that listen for a held key.
@MainActor
final class ShortcutCapture: ObservableObject {
    enum Outcome {
        case record(KeyShortcut)
        case clear
        case cancel
    }

    @Published private(set) var recording = false
    /// The modifiers held so far, drawn while recording.
    @Published private(set) var preview = ""
    private var monitor: Any?
    private var finish: ((Outcome) -> Void)?
    private var held: KeyShortcut.Modifiers = []
    private var peak: KeyShortcut.Modifiers = []
    private var lastModifierKey: UInt16?
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
        preview = ""
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged], handler: { [weak self] event in
            guard let self, self.handle(event) else { return event }
            return nil
        })
    }

    func cancel() {
        guard recording else { return }
        complete(.cancel)
    }

    /// Returns true when the key press belonged to the recording, so no one else gets it.
    private func handle(_ event: NSEvent) -> Bool {
        guard recording else { return false }
        // Keys Kinesis posts for a gesture are not the person typing.
        guard event.cgEvent?.getIntegerValueField(.eventSourceUserData) != MacShortcuts.shortcutEventTag else { return false }
        let flags = Self.modifiers(event.modifierFlags)
        if event.type == .flagsChanged {
            if flags.isEmpty {
                // Everything let go with no key in between: the modifier is the shortcut.
                if let key = lastModifierKey {
                    let name = KeyShortcut.name(forKeyCode: key) ?? "key \(key)"
                    complete(.record(KeyShortcut(keyCode: key, modifiers: peak, key: name)))
                }
            } else {
                if !flags.subtracting(held).isEmpty, KeyShortcut.modifierKeys[event.keyCode] != nil {
                    lastModifierKey = event.keyCode
                }
                peak.formUnion(flags)
                preview = KeyShortcut.Modifiers.ordered.filter { flags.contains($0.modifier) }.map(\.symbol).joined()
            }
            held = flags
            return true
        }
        guard event.type == .keyDown, !event.isARepeat else { return true }
        var modifiers = flags
        if KeyShortcut.keysCarryingFunctionFlag.contains(event.keyCode) { modifiers.remove(.function) }
        if modifiers.isEmpty && event.keyCode == 53 {
            complete(.cancel)
        } else if modifiers.isEmpty && (event.keyCode == 51 || event.keyCode == 117) {
            complete(.clear)
        } else {
            complete(.record(KeyShortcut(keyCode: event.keyCode, modifiers: modifiers, key: Self.keyName(event))))
        }
        return true
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
