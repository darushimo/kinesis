import AppKit
import OSLog
import SwiftUI
import KinesisCore

/// One key event, reduced to what the recorder needs. It is plain data, so it can be read
/// where macOS delivers the event and handed to the recorder.
struct KeyPress: Sendable {
    enum Kind: Sendable { case down, up, modifiers }
    let kind: Kind
    let keyCode: UInt16
    let modifiers: KeyShortcut.Modifiers
    let isRepeat: Bool
    /// Posted by Kinesis for a gesture, not typed.
    let fromKinesis: Bool
    let name: String

    init?(_ event: CGEvent, type: CGEventType) {
        switch type {
        case .keyDown: kind = .down
        case .keyUp: kind = .up
        case .flagsChanged: kind = .modifiers
        default: return nil
        }
        keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        var modifiers: KeyShortcut.Modifiers = []
        if flags.contains(.maskControl) { modifiers.insert(.control) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        if flags.contains(.maskCommand) { modifiers.insert(.command) }
        if flags.contains(.maskSecondaryFn) { modifiers.insert(.function) }
        self.modifiers = modifiers
        isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        fromKinesis = event.getIntegerValueField(.eventSourceUserData) == MacShortcuts.shortcutEventTag
        name = kind == .down ? Self.name(keyCode, NSEvent(cgEvent: event)) : ""
    }

    init?(_ event: NSEvent) {
        switch event.type {
        case .keyDown: kind = .down
        case .keyUp: kind = .up
        case .flagsChanged: kind = .modifiers
        default: return nil
        }
        keyCode = event.keyCode
        modifiers = ShortcutCapture.modifiers(event.modifierFlags)
        isRepeat = kind != .modifiers && event.isARepeat
        fromKinesis = event.cgEvent?.getIntegerValueField(.eventSourceUserData) == MacShortcuts.shortcutEventTag
        name = kind == .down ? Self.name(keyCode, event) : ""
    }

    static func name(_ keyCode: UInt16, _ event: NSEvent?) -> String {
        if let name = KeyShortcut.name(forKeyCode: keyCode) { return name }
        // The key's own character, as if no modifier were held: K, not ˚ for ⌥K.
        if let characters = event?.characters(byApplyingModifiers: []), !characters.isEmpty {
            return characters.uppercased()
        }
        return "key \(keyCode)"
    }
}

/// Sees keys while a recorder is listening, ahead of every app's own shortcuts. Without it, a
/// shortcut another app already owns, such as ⌥Space for a quick-entry window, goes to that
/// app and never reaches the recorder.
private func recorderTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                 refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { ShortcutCapture.active?.resumeTap() }
        return Unmanaged.passUnretained(event)
    }
    guard let press = KeyPress(event, type: type) else { return Unmanaged.passUnretained(event) }
    let taken = MainActor.assumeIsolated { ShortcutCapture.active?.handle(press) ?? false }
    return taken ? nil : Unmanaged.passUnretained(event)
}

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
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var finish: ((Outcome) -> Void)?
    /// Modifiers down right now, and every modifier pressed since recording began.
    private var held: KeyShortcut.Modifiers = []
    private var peak: KeyShortcut.Modifiers = []
    private var lastModifierKey: UInt16?
    /// The ordinary key in the chord, and the ordinary keys still down.
    private var mainKey: (code: UInt16, name: String)?
    private var keysDown: Set<UInt16> = []
    /// Only one recorder listens at a time.
    fileprivate static weak var active: ShortcutCapture?
    private static let log = Logger(subsystem: "local.callbacked.kinesis", category: "shortcuts")

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
        startTap()
        // Without the system-level listener, as before Accessibility is allowed, Kinesis
        // still records whatever keys reach its own window.
        if tap == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged], handler: { [weak self] event in
                guard let self, let press = KeyPress(event), self.handle(press) else { return event }
                return nil
            })
        }
    }

    func cancel() {
        guard recording else { return }
        complete(.cancel)
    }

    private func startTap() {
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
        // The hardware-event level first. Shortcuts other apps own, such as ⌥Space, are taken
        // away before the session level ever sees them; this level sees them first.
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: recorderTapCallback, userInfo: nil)
                ?? CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                     eventsOfInterest: mask, callback: recorderTapCallback, userInfo: nil) else {
            Self.log.notice("Shortcut recorder: no event tap, listening to Kinesis's own window only")
            // Listening to every key needs Input Monitoring. Ask, so the next recording can.
            _ = CGRequestListenEventAccess()
            return
        }
        Self.log.notice("Shortcut recorder: listening through an event tap")
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        tapSource = source
    }

    /// macOS turns a listener off if it ever takes too long. Turn it back on while recording.
    fileprivate func resumeTap() {
        if recording, let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    private func stopTap() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tap = nil
        tapSource = nil
    }

    /// The chord as pressed so far, with fn left off keys that always carry it.
    private var chord: KeyShortcut.Modifiers {
        guard let mainKey, KeyShortcut.keysCarryingFunctionFlag.contains(mainKey.code) else { return peak }
        return peak.subtracting(.function)
    }

    /// Returns true when the key event belonged to the recording, so no one else gets it.
    fileprivate func handle(_ press: KeyPress) -> Bool {
        guard recording else { return false }
        Self.log.debug("Shortcut recorder saw key \(press.keyCode, privacy: .public) \(String(describing: press.kind), privacy: .public) modifiers \(press.modifiers.rawValue, privacy: .public)")
        // Keys Kinesis posts for a gesture are not the person typing.
        guard !press.fromKinesis else { return false }
        switch press.kind {
        case .modifiers:
            let flags = press.modifiers
            if !flags.subtracting(held).isEmpty, KeyShortcut.modifierKeys[press.keyCode] != nil {
                lastModifierKey = press.keyCode
            }
            // Only real modifier presses count, not the fn flag macOS adds to arrows and F-keys.
            peak.formUnion(flags)
            held = flags
        case .down:
            guard !press.isRepeat else { return true }
            let plain = held.isEmpty && keysDown.isEmpty && mainKey == nil
            if plain && press.keyCode == 53 {
                complete(.cancel)
                return true
            }
            if plain && (press.keyCode == 51 || press.keyCode == 117) {
                complete(.clear)
                return true
            }
            keysDown.insert(press.keyCode)
            mainKey = (press.keyCode, press.name)
        case .up:
            keysDown.remove(press.keyCode)
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
        stopTap()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        finish = nil
        recording = false
        preview = ""
        if Self.active === self { Self.active = nil }
    }

    nonisolated static func modifiers(_ flags: NSEvent.ModifierFlags) -> KeyShortcut.Modifiers {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        var modifiers: KeyShortcut.Modifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.function) { modifiers.insert(.function) }
        return modifiers
    }
}

/// A key you can pick from a list, for building a shortcut by clicking instead of typing.
struct ShortcutKeyChoice: Hashable, Sendable {
    let code: UInt16
    let name: String

    static let all: [ShortcutKeyChoice] = {
        let named: [UInt16] = [49, 36, 48, 53, 51, 123, 124, 125, 126,
                               122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        let letters: [(String, UInt16)] = [("A", 0), ("B", 11), ("C", 8), ("D", 2), ("E", 14), ("F", 3), ("G", 5), ("H", 4),
                                           ("I", 34), ("J", 38), ("K", 40), ("L", 37), ("M", 46), ("N", 45), ("O", 31),
                                           ("P", 35), ("Q", 12), ("R", 15), ("S", 1), ("T", 17), ("U", 32), ("V", 9),
                                           ("W", 13), ("X", 7), ("Y", 16), ("Z", 6)]
        let digits: [(String, UInt16)] = [("0", 29), ("1", 18), ("2", 19), ("3", 20), ("4", 21), ("5", 23), ("6", 22),
                                          ("7", 26), ("8", 28), ("9", 25)]
        return named.map { ShortcutKeyChoice(code: $0, name: KeyShortcut.name(forKeyCode: $0) ?? "key \($0)") }
            + (letters + digits).map { ShortcutKeyChoice(code: $0.1, name: $0.0) }
    }()
}

/// Builds a shortcut from clicks: the modifiers, then the key. Nothing has to be typed, so a
/// shortcut another app keeps for itself can still be chosen.
struct ShortcutEditor: View {
    let save: (KeyShortcut) -> Void
    @State private var modifiers: KeyShortcut.Modifiers
    @State private var key: ShortcutKeyChoice

    init(shortcut: KeyShortcut?, save: @escaping (KeyShortcut) -> Void) {
        self.save = save
        let existing = shortcut.flatMap { current in ShortcutKeyChoice.all.first { $0.code == current.keyCode } }
        _modifiers = State(initialValue: existing == nil ? [.option] : shortcut?.heldModifiers ?? [.option])
        _key = State(initialValue: existing ?? ShortcutKeyChoice.all[0])
    }

    private var result: KeyShortcut { KeyShortcut(keyCode: key.code, modifiers: modifiers, key: key.name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("pick the keys").font(KinesisType.label)
            HStack(spacing: 6) {
                ForEach(KeyShortcut.Modifiers.ordered.indices, id: \.self) { index in
                    let entry = KeyShortcut.Modifiers.ordered[index]
                    let on = modifiers.contains(entry.modifier)
                    Button {
                        modifiers.formSymmetricDifference(entry.modifier)
                    } label: {
                        Text(entry.symbol).font(KinesisType.label)
                            .foregroundStyle(on ? KinesisStyle.accent : KinesisStyle.secondary)
                            .frame(minWidth: 22).padding(.horizontal, 9).padding(.vertical, 7)
                            .background(PillSurface(fill: on ? KinesisStyle.chip : KinesisStyle.tray, raised: on))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            PillMenu(options: ShortcutKeyChoice.all.map { Choice($0, $0.name) }, selection: key,
                     select: { key = $0 }, label: "Key")
            HStack {
                Text(result.display).font(KinesisType.headline)
                Spacer()
                Button("save") { save(result) }.buttonStyle(KinesisButtonStyle(prominent: true))
            }
        }
        .padding(18)
        .frame(width: 280)
    }
}

/// A pill that shows a recorded shortcut. Click it and press keys to record a new one, or
/// use the button beside it to pick the keys from a list.
struct ShortcutRecorder: View {
    let shortcut: KeyShortcut?
    let record: (KeyShortcut?) -> Void
    var label = ""
    @StateObject private var capture = ShortcutCapture()
    @State private var hovered = false
    @State private var picking = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var text: String {
        if capture.recording { return capture.preview.isEmpty ? "type a shortcut" : capture.preview + "…" }
        return shortcut?.display ?? "record shortcut"
    }

    var body: some View {
        HStack(spacing: 6) {
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
            .animation(reduceMotion ? nil : KinesisMotion.settle, value: capture.recording)
            .accessibilityLabel(label)
            .accessibilityValue(capture.recording ? "recording" : shortcut?.display ?? "none")
            .accessibilityHint("Activate, then press the keys. Escape cancels, Delete clears.")

            Button {
                capture.cancel()
                picking = true
            } label: {
                Image(systemName: "slider.horizontal.3").font(.system(size: 11))
                    .foregroundStyle(KinesisStyle.secondary)
                    .padding(9)
                    .background(PillSurface(fill: KinesisStyle.tray))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("pick the keys instead of typing them")
            .accessibilityLabel(label + ", pick the keys")
            .popover(isPresented: $picking, arrowEdge: .bottom) {
                ShortcutEditor(shortcut: shortcut) { picked in
                    record(picked)
                    picking = false
                }
            }
        }
        .onDisappear { capture.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in capture.cancel() }
    }
}
