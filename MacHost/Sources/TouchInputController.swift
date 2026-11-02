import Cocoa
import ApplicationServices

/// Main-thread bridge between source-time gestures and macOS input events.
final class TouchInputController {
    private let settings: DisplaySettings
    private let boundsProvider: () -> CGRect?
    private let engine = TouchGestureEngine()
    private let source = CGEventSource(stateID: .privateState)
    private lazy var zoom = TouchZoomController(settings: settings, eventSource: source)
    private var mouseIsDown = false
    private var lastMousePoint = CGPoint.zero
    private var scrollActive = false
    private var scrollRemainder = CGPoint.zero
    private var scrollAnchor = CGPoint.zero
    private var momentumTimer: Timer?
    private var momentumVelocity = CGPoint.zero
    private var momentumStart: UInt64 = 0
    private var momentumLastTime: Double = 0
    private var momentumDistance: Double = 0
    private var momentumBegan = false
    private var epoch: UInt64 = 0
    private var legacySequence: UInt64 = 0
    private var lastDiagnosticTime: UInt64 = 0

    init(settings: DisplaySettings, boundsProvider: @escaping () -> CGRect?) {
        self.settings = settings
        self.boundsProvider = boundsProvider
    }

    func handle(_ frame: TouchInputFrame) {
        guard Thread.isMainThread else {
            assertionFailure("Touch input must execute on the main thread")
            return
        }
        guard settings.touchEnabled, boundsProvider() != nil, AXIsProcessTrusted() else {
            cancel(reason: "Touch input unavailable")
            if !AXIsProcessTrusted() {
                settings.hasAccessibilityPermission = false
                settings.touchStatus = "Enable Accessibility permission to control the Mac."
            }
            return
        }
        let braking = momentumTimer != nil
        let actions = engine.process(frame, preferences: settings.touchPreferences,
                                     doubleClickMilliseconds: NSEvent.doubleClickInterval * 1000,
                                     braking: braking)
        execute(actions)
        if settings.touchPreferences.diagnostics {
            let now = DispatchTime.now().uptimeNanoseconds
            if now - lastDiagnosticTime >= 200_000_000 || frame.phase != .move {
                lastDiagnosticTime = now
                debugLog("Touch v2 seq=\(frame.sequence) phase=\(frame.phase) contacts=\(frame.contacts.count) actions=\(actions.count) sample=\(frame.timestampMs)")
            }
        }
    }

    func handleLegacy(x: Float, y: Float, action: Int, pointerCount: Int, x2: Float, y2: Float) {
        guard let bounds = boundsProvider(), let phase = TouchPhase(rawValue: UInt8(clamping: action)) else { return }
        legacySequence &+= 1
        func contact(_ id: Int32, _ x: Float, _ y: Float) -> TouchContact {
            TouchContact(id: id, x: settings.flipHorizontal ? 1 - Double(x) : Double(x),
                         y: settings.flipVertical ? 1 - Double(y) : Double(y), tool: 1)
        }
        let count = min(2, max(1, pointerCount))
        let translated: TouchPhase = count == 2 ? (phase == .down ? .pointerDown : phase == .up ? .pointerUp : phase) : phase
        let contacts = phase == .cancel ? [] : count == 2 ? [contact(0, x, y), contact(1, x2, y2)] : [contact(0, x, y)]
        guard contacts.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { cancel(reason: "Invalid touch coordinates"); return }
        handle(TouchInputFrame(sessionToken: 0, sequence: legacySequence,
                               timestampMs: DispatchTime.now().uptimeNanoseconds / 1_000_000,
                               phase: translated, changedPointerID: count == 2 ? 1 : 0,
                               viewportWidthDp: max(1, Double(bounds.width)),
                               viewportHeightDp: max(1, Double(bounds.height)), contacts: contacts))
    }

    func cancel(reason: String) {
        epoch &+= 1
        execute(engine.cancel())
        stopMomentum()
        zoom.cancel()
        if mouseIsDown { mouse(.leftMouseUp, at: lastMousePoint) }
        if scrollActive { emitScroll(.zero, phase: .cancelled) }
        scrollActive = false
        scrollRemainder = .zero
        if settings.touchPreferences.diagnostics { debugLog("Touch cancelled: \(reason)") }
    }

    private func execute(_ actions: [TouchGestureEngine.Action]) {
        for action in actions {
            switch action {
            case .cursor(let p): if let point = desktop(p) { mouse(.mouseMoved, at: point) }
            case .click(let p, let count, let right):
                guard let point = desktop(p) else { continue }
                mouse(right ? .rightMouseDown : .leftMouseDown, at: point, count: count)
                mouse(right ? .rightMouseUp : .leftMouseUp, at: point, count: count)
            case .mouseDown(let p): if let point = desktop(p) { mouse(.leftMouseDown, at: point) }
            case .mouseDrag(let p): if let point = desktop(p), mouseIsDown { mouse(.leftMouseDragged, at: point) }
            case .mouseUp(let p): if mouseIsDown { mouse(.leftMouseUp, at: desktop(p) ?? lastMousePoint) }
            case .scroll(let delta, let anchor, let phase):
                if let position = desktop(anchor) { scrollAnchor = position }
                emitScroll(delta, phase: phase)
            case .momentum(let velocity, let anchor):
                if let position = desktop(anchor) { scrollAnchor = position }
                startMomentum(velocity)
            case .stopMomentum: stopMomentum()
            case .prepareZoom(let p): if let point = desktop(p) { zoom.prepare(at: point) }
            case .zoom(let delta): zoom.add(logScale: delta)
            case .endZoom: zoom.cancel()
            }
        }
    }

    private func desktop(_ p: CGPoint) -> CGPoint? {
        guard let bounds = boundsProvider() else { return nil }
        let rawX = min(1, max(0, p.x)), rawY = min(1, max(0, p.y))
        let x = settings.flipHorizontal ? 1 - rawX : rawX
        let y = settings.flipVertical ? 1 - rawY : rawY
        return CGPoint(x: bounds.minX + x * max(0, bounds.width - 1),
                       y: bounds.minY + y * max(0, bounds.height - 1))
    }

    private func mouse(_ type: CGEventType, at point: CGPoint, count: Int = 1) {
        let right = type == .rightMouseDown || type == .rightMouseUp
        guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: right ? .right : .left) else { return }
        event.flags = []
        event.setIntegerValueField(.mouseEventClickState, value: Int64(count))
        event.post(tap: .cghidEventTap)
        if type == .leftMouseDown { mouseIsDown = true }
        if type == .leftMouseUp { mouseIsDown = false }
        lastMousePoint = point
    }

    private func mappedDelta(_ delta: CGPoint) -> CGPoint {
        guard let bounds = boundsProvider() else { return .zero }
        let preferences = settings.touchPreferences
        let direction: CGFloat = preferences.followFinger ? 1 : -1
        let sensitivity = CGFloat(min(3, max(0.2, preferences.sensitivity)))
        return CGPoint(x: delta.x / engine.viewport.width * bounds.width * (settings.flipHorizontal ? -1 : 1) * direction * sensitivity,
                       y: delta.y / engine.viewport.height * bounds.height * (settings.flipVertical ? -1 : 1) * direction * sensitivity)
    }

    private func emitScroll(_ deltaDp: CGPoint, phase: TouchGestureEngine.ScrollPhase? = nil, momentumPhase: Int64 = 0) {
        if phase == .began { scrollRemainder = .zero; scrollActive = true }
        let mapped = mappedDelta(deltaDp)
        let x = mapped.x + scrollRemainder.x, y = mapped.y + scrollRemainder.y
        let wholeX = x.rounded(.towardZero), wholeY = y.rounded(.towardZero)
        scrollRemainder = CGPoint(x: x - wholeX, y: y - wholeY)
        let boundary = phase == .began || phase == .ended || phase == .cancelled || momentumPhase == 1 || momentumPhase == 3
        guard wholeX != 0 || wholeY != 0 || boundary else { return }
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                  wheel1: Int32(clamping: Int64(wholeY)), wheel2: Int32(clamping: Int64(wholeX)), wheel3: 0) else { return }
        event.flags = []
        event.location = scrollAnchor
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        let scrollPhase: Int64
        switch phase {
        case .began: scrollPhase = 1
        case .changed: scrollPhase = 2
        case .ended: scrollPhase = 4
        case .cancelled: scrollPhase = 8
        case nil: scrollPhase = 0
        }
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: scrollPhase)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentumPhase)
        event.post(tap: .cghidEventTap)
        if phase == .ended || phase == .cancelled { scrollActive = false; scrollRemainder = .zero }
        if settings.touchPreferences.diagnostics, boundary {
            debugLog("Touch scroll x=\(wholeX) y=\(wholeY) phase=\(scrollPhase) momentum=\(momentumPhase)")
        }
    }

    private func startMomentum(_ velocity: CGPoint) {
        stopMomentum()
        guard settings.touchPreferences.momentum != .off else { return }
        momentumVelocity = velocity
        momentumStart = DispatchTime.now().uptimeNanoseconds
        momentumLastTime = 0; momentumDistance = 0; momentumBegan = false
        let currentEpoch = epoch
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self, self.epoch == currentEpoch else { return }
            self.momentumTick()
        }
        momentumTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func momentumTick() {
        guard settings.touchEnabled, boundsProvider() != nil else { stopMomentum(); return }
        let weakMomentum = settings.touchPreferences.momentum == .weak
        let maximumTime = weakMomentum ? 0.25 : 0.7
        let maximumDistance = Double(min(engine.viewport.width, engine.viewport.height)) * (weakMomentum ? 0.15 : 0.6)
        let tau = weakMomentum ? 0.075 : 0.22
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - momentumStart) / 1_000_000_000
        let t = min(maximumTime, elapsed)
        let integral = tau * (exp(-momentumLastTime / tau) - exp(-t / tau))
        var delta = CGPoint(x: momentumVelocity.x * integral, y: momentumVelocity.y * integral)
        let distance = hypot(Double(delta.x), Double(delta.y))
        if distance > maximumDistance - momentumDistance, distance > 0 {
            let ratio = max(0, maximumDistance - momentumDistance) / distance
            delta.x *= ratio; delta.y *= ratio
        }
        momentumDistance += hypot(Double(delta.x), Double(delta.y))
        emitScroll(delta, momentumPhase: momentumBegan ? 2 : 1)
        momentumBegan = true
        momentumLastTime = t
        if elapsed >= maximumTime || momentumDistance >= maximumDistance ||
            hypot(Double(momentumVelocity.x), Double(momentumVelocity.y)) * exp(-t / tau) < 15 {
            stopMomentum()
        }
    }

    private func stopMomentum() {
        momentumTimer?.invalidate()
        momentumTimer = nil
        if momentumBegan { emitScroll(.zero, momentumPhase: 3) }
        momentumBegan = false
        scrollRemainder = .zero
    }
}
