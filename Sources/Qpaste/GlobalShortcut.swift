import AppKit
import Carbon
import ApplicationServices
import QpasteCore

@MainActor
final class GlobalShortcut {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var permissionTimer: Timer?
    private var permissionGranted: Bool?
    private var doubleTap = CommandDoubleTap(interval: NSEvent.doubleClickInterval)
    var onPress: (() -> Void)?
    var onStatusChange: ((String?) -> Void)?

    private let watchedEvents: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]

    init() {
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                          EventParamType(typeEventHotKeyID), nil,
                                          MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard status == noErr, identifier.signature == 0x51505354, identifier.id == 1 else {
                return OSStatus(eventNotHandledErr)
            }
            MainActor.assumeIsolated {
                Unmanaged<GlobalShortcut>.fromOpaque(context).takeUnretainedValue().onPress?()
            }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    func register(_ choice: ShortcutChoice) {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        stopDoubleTap()
        if choice == .doubleCommand {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: watchedEvents) { [weak self] event in
                MainActor.assumeIsolated { self?.observe(event) }
                return event
            }
            refreshPermission()
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshPermission() }
            }
            if let permissionTimer { RunLoop.main.add(permissionTimer, forMode: .common) }
            return
        }
        let identifier = EventHotKeyID(signature: 0x51505354, id: 1)
        let success = RegisterEventHotKey(UInt32(kVK_ANSI_V), choice.modifiers, identifier,
                                          GetApplicationEventTarget(), 0, &hotKey) == noErr
        onStatusChange?(success ? nil : "快捷键 \(choice.label) 已被占用，请在设置中换一个。")
    }

    private func refreshPermission() {
        let allowed = AXIsProcessTrusted()
        guard allowed != permissionGranted else { return }
        permissionGranted = allowed
        doubleTap.reset()
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor); self.globalMonitor = nil }
        if allowed {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: watchedEvents) { [weak self] event in
                MainActor.assumeIsolated { self?.observe(event) }
            }
            onStatusChange?(globalMonitor != nil && localMonitor != nil ? nil : "双击 ⌘ 监听未能启动，请重新选择快捷键。")
        } else {
            onStatusChange?("在其他应用中使用双击 ⌘，需要开启 Qpaste 的辅助功能权限。")
        }
    }

    private func observe(_ event: NSEvent) {
        guard event.type == .flagsChanged,
              event.keyCode == UInt16(kVK_Command) || event.keyCode == UInt16(kVK_RightCommand),
              event.modifierFlags.intersection([.shift, .control, .option, .function]).isEmpty else {
            doubleTap.reset()
            return
        }
        if doubleTap.commandChanged(isDown: event.modifierFlags.contains(.command), at: event.timestamp) {
            onPress?()
        }
    }

    func cancelDoubleTap() { doubleTap.reset() }

    private func stopDoubleTap() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor); self.globalMonitor = nil }
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        permissionTimer?.invalidate()
        permissionTimer = nil
        permissionGranted = nil
        doubleTap.reset()
    }

    func stop() {
        stopDoubleTap()
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        if let handler { RemoveEventHandler(handler); self.handler = nil }
    }
}
