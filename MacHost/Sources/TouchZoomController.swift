import Cocoa
import ApplicationServices
import Carbon

/// A pinch chooses exactly one zoom backend and one target window.
final class TouchZoomController {
    private struct Target {
        let pid: pid_t
        let bundleID: String
        let application: AXUIElement
        let window: AXUIElement
        let running: NSRunningApplication
        let point: CGPoint
    }
    private struct Shortcut { let keyCode: CGKeyCode; let flags: CGEventFlags }
    private enum Backend {
        case menus(AXUIElement, AXUIElement)
        case shortcuts(Shortcut, Shortcut)
        case wheel(CGEventFlags)
    }
    private let settings: DisplaySettings
    private let eventSource: CGEventSource?
    private var target: Target?
    private var backend: Backend?
    private var pendingScale = 0.0
    private var lastOutput: UInt64 = 0
    private var generation: UInt64 = 0
    private var activating = false
    private var active = false
    private var failed = false
    private var scheduled: DispatchWorkItem?
    private let step = log(1.10)

    init(settings: DisplaySettings, eventSource: CGEventSource?) {
        self.settings = settings
        self.eventSource = eventSource
    }

    func prepare(at point: CGPoint) {
        cancel()
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.08)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &element) == .success,
              let hit = element else { return }
        var pid: pid_t = 0
        guard AXUIElementGetPid(hit, &pid) == .success,
              let running = NSRunningApplication(processIdentifier: pid), let bundle = running.bundleIdentifier else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.08)
        let window: AXUIElement?
        if (attribute(hit, kAXRoleAttribute) as? String) == kAXWindowRole { window = hit }
        else { window = elementAttribute(hit, kAXWindowAttribute) }
        guard let window else { return }
        target = Target(pid: pid, bundleID: bundle, application: app, window: window, running: running, point: point)
    }

    func add(logScale: Double) {
        guard logScale.isFinite, !failed else { return }
        pendingScale = min(2.0, max(-2.0, pendingScale + logScale))
        guard abs(pendingScale) >= step else { return }
        if !active && !activating { begin() }
        if active { flush() }
    }

    func cancel() {
        generation &+= 1
        scheduled?.cancel(); scheduled = nil
        target = nil; backend = nil
        pendingScale = 0; lastOutput = 0
        activating = false; active = false; failed = false
    }

    private func begin() {
        guard let target else { fail("No zoomable window under your fingers."); return }
        let binding = settings.zoomBindings[target.bundleID] ?? TouchZoomBinding()
        switch binding.method {
        case .automatic:
            guard isKnownApplication(target.bundleID) else {
                fail("Set a zoom method for this app in Touch Control."); return
            }
            guard let selected = automaticBackend(for: target) else {
                fail("This window has no available Zoom In / Zoom Out commands."); return
            }
            backend = selected
        case .commandWheel: backend = .wheel(.maskCommand)
        case .controlWheel: backend = .wheel(.maskControl)
        case .optionWheel: backend = .wheel(.maskAlternate)
        case .shortcuts:
            guard let zoomIn = parseShortcut(binding.zoomInShortcut), let zoomOut = parseShortcut(binding.zoomOutShortcut) else {
                fail("Check this app's zoom shortcuts in Touch Control."); return
            }
            backend = .shortcuts(zoomIn, zoomOut)
        case .disabled:
            fail("Pinch zoom is disabled for this app."); return
        }
        if isFocused(target) { active = true; flush(); return }
        activating = true
        AXUIElementPerformAction(target.window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(target.window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(target.application, kAXFocusedWindowAttribute as CFString, target.window)
        target.running.activate(options: [.activateIgnoringOtherApps])
        let token = generation
        let deadline = DispatchTime.now().uptimeNanoseconds + 200_000_000
        pollFocus(token: token, deadline: deadline)
    }

    private func pollFocus(token: UInt64, deadline: UInt64) {
        guard token == generation, activating, let target else { return }
        scheduled = nil
        if isFocused(target) {
            activating = false; active = true; flush()
        } else if DispatchTime.now().uptimeNanoseconds >= deadline {
            fail("Could not focus the window for pinch zoom.")
        } else {
            let item = DispatchWorkItem { [weak self] in self?.pollFocus(token: token, deadline: deadline) }
            scheduled = item
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(20), execute: item)
        }
    }

    private func flush() {
        guard active, !failed, abs(pendingScale) >= step, let target, let backend else { return }
        guard isFocused(target) else { fail("Pinch zoom stopped because the target window changed."); return }
        let now = DispatchTime.now().uptimeNanoseconds
        if lastOutput != 0 && now - lastOutput < 100_000_000 {
            scheduleFlush(after: 100_000_000 - (now - lastOutput)); return
        }
        let enlarge = pendingScale > 0
        let succeeded: Bool
        switch backend {
        case .menus(let zoomIn, let zoomOut):
            let item = enlarge ? zoomIn : zoomOut
            if (attribute(item, kAXEnabledAttribute) as? Bool) == false { pendingScale = 0; return }
            succeeded = AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
        case .shortcuts(let zoomIn, let zoomOut):
            succeeded = post(enlarge ? zoomIn : zoomOut)
        case .wheel(let flags):
            if let event = CGEvent(scrollWheelEvent2Source: eventSource, units: .line, wheelCount: 1,
                                   wheel1: enlarge ? 1 : -1, wheel2: 0, wheel3: 0) {
                event.location = target.point
                event.flags = flags
                event.post(tap: .cghidEventTap)
                succeeded = true
            } else { succeeded = false }
        }
        guard succeeded else { fail("The app did not accept its zoom command."); return }
        pendingScale -= enlarge ? step : -step
        lastOutput = now
        settings.touchStatus = "Pinch zoom · \(target.running.localizedName ?? target.bundleID)"
        if settings.touchPreferences.diagnostics {
            debugLog("Touch zoom app=\(target.bundleID) direction=\(enlarge ? "in" : "out")")
        }
        if abs(pendingScale) >= step { scheduleFlush(after: 100_000_000) }
    }

    private func scheduleFlush(after nanoseconds: UInt64) {
        guard scheduled == nil || scheduled?.isCancelled == true else { return }
        let token = generation
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token else { return }
            self.scheduled = nil
            self.flush()
        }
        scheduled = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .nanoseconds(Int(nanoseconds)), execute: item)
    }

    private func fail(_ message: String) {
        scheduled?.cancel(); scheduled = nil
        pendingScale = 0; active = false; activating = false; failed = true
        settings.touchStatus = message
        if settings.touchPreferences.diagnostics { debugLog("Touch zoom: \(message)") }
    }

    private func isFocused(_ target: Target) -> Bool {
        guard !target.running.isTerminated,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid,
              let focused = elementAttribute(target.application, kAXFocusedWindowAttribute), CFEqual(focused, target.window) else { return false }
        let sheets = attribute(target.window, "AXSheets") as? [AXUIElement] ?? []
        return sheets.isEmpty && (attribute(focused, kAXModalAttribute) as? Bool) != true
    }

    private func isKnownApplication(_ bundle: String) -> Bool {
        let known = ["com.google.Chrome", "com.google.Chrome.canary", "org.chromium.Chromium",
                     "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser",
                     "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "com.apple.Safari",
                     "com.apple.SafariTechnologyPreview", "com.apple.Preview"]
        return known.contains(bundle)
    }

    private func automaticBackend(for target: Target) -> Backend? {
        let standard: Backend?
        if let plus = parseShortcut("cmd++"), let minus = parseShortcut("cmd+-") {
            standard = .shortcuts(plus, minus)
        } else { standard = nil }
        guard let menuBar = elementAttribute(target.application, kAXMenuBarAttribute) else { return standard }
        let inTitles: Set<String> = ["zoom in", "放大", "放大显示", "放大顯示", "拡大", "agrandir", "vergrößern", "acercar"]
        let outTitles: Set<String> = ["zoom out", "缩小", "縮小", "缩小显示", "縮小顯示", "réduire", "verkleinern", "alejar"]
        var stack: [(AXUIElement, Int)] = [(menuBar, 0)]
        var zoomIn: [AXUIElement] = [], zoomOut: [AXUIElement] = []
        var visited = 0
        let deadline = DispatchTime.now().uptimeNanoseconds + 180_000_000
        while let (element, depth) = stack.popLast(), visited < 320, DispatchTime.now().uptimeNanoseconds < deadline {
            visited += 1
            if let title = attribute(element, kAXTitleAttribute) as? String {
                let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if inTitles.contains(normalized) { zoomIn.append(element) }
                if outTitles.contains(normalized) { zoomOut.append(element) }
            }
            if depth < 8, let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
                stack.append(contentsOf: children.reversed().map { ($0, depth + 1) })
            }
        }
        guard zoomIn.count == 1, zoomOut.count == 1 else { return standard }
        let plus = zoomIn[0], minus = zoomOut[0]
        if supportsPress(plus), supportsPress(minus) { return .menus(plus, minus) }
        if let inShortcut = menuShortcut(plus), let outShortcut = menuShortcut(minus) {
            return .shortcuts(inShortcut, outShortcut)
        }
        return standard
    }

    private func supportsPress(_ element: AXUIElement) -> Bool {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return false }
        return (names as? [String])?.contains(kAXPressAction) == true
    }

    private func menuShortcut(_ element: AXUIElement) -> Shortcut? {
        guard let modifiers = attribute(element, "AXMenuItemCmdModifiers") as? NSNumber else { return nil }
        let bits = modifiers.intValue
        var flags: CGEventFlags = []
        if bits & 8 == 0 { flags.insert(.maskCommand) }
        if bits & 1 != 0 { flags.insert(.maskShift) }
        if bits & 2 != 0 { flags.insert(.maskAlternate) }
        if bits & 4 != 0 { flags.insert(.maskControl) }
        if let virtual = attribute(element, "AXMenuItemCmdVirtualKey") as? NSNumber {
            return Shortcut(keyCode: CGKeyCode(clamping: virtual.intValue), flags: flags)
        }
        guard let character = attribute(element, "AXMenuItemCmdChar") as? String,
              let (key, extra) = keyCode(for: character) else { return nil }
        return Shortcut(keyCode: key, flags: flags.union(extra))
    }

    private func parseShortcut(_ value: String) -> Shortcut? {
        let parts = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .split(separator: "+", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespaces) }
        guard !parts.isEmpty else { return nil }
        let keyName: String
        let modifiers: [String]
        if parts.count >= 2, parts.suffix(2).allSatisfy({ $0.isEmpty }) {
            keyName = "+"; modifiers = Array(parts.dropLast(2))
        } else {
            keyName = parts.last ?? ""; modifiers = Array(parts.dropLast())
        }
        var flags: CGEventFlags = []
        for modifier in modifiers {
            switch modifier {
            case "cmd", "command", "⌘": flags.insert(.maskCommand)
            case "ctrl", "control", "⌃": flags.insert(.maskControl)
            case "alt", "option", "⌥": flags.insert(.maskAlternate)
            case "shift", "⇧": flags.insert(.maskShift)
            default: return nil
            }
        }
        guard let (key, extra) = keyCode(for: keyName) else { return nil }
        return Shortcut(keyCode: key, flags: flags.union(extra))
    }

    private func keyCode(for character: String) -> (CGKeyCode, CGEventFlags)? {
        let named: [String: CGKeyCode] = ["return": 36, "enter": 36, "tab": 48, "space": 49,
                                        "escape": 53, "esc": 53, "left": 123, "right": 124,
                                        "down": 125, "up": 126, "delete": 51, "home": 115,
                                        "end": 119, "pageup": 116, "pagedown": 121]
        if let key = named[character] { return (key, []) }
        guard character.count == 1, let input = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(input, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = unsafeBitCast(property, to: CFData.self)
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        for shifted in [false, true] {
            for code: UInt16 in 0..<128 {
                var dead: UInt32 = 0
                var count: Int = 0
                var characters = [UniChar](repeating: 0, count: 8)
                let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDisplay), shifted ? UInt32(shiftKey >> 8) : 0,
                                            UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead,
                                            characters.count, &count, &characters)
                if status == noErr, count > 0, String(utf16CodeUnits: characters, count: count) == character {
                    return (CGKeyCode(code), shifted ? .maskShift : [])
                }
            }
        }
        return nil
    }

    private func post(_ shortcut: Shortcut) -> Bool {
        guard let down = CGEvent(keyboardEventSource: eventSource, virtualKey: shortcut.keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: eventSource, virtualKey: shortcut.keyCode, keyDown: false) else { return false }
        down.flags = shortcut.flags; up.flags = shortcut.flags
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        return true
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    private func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}
