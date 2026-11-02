import Foundation
import CoreGraphics

/// Source-time gesture recognition; it never posts operating-system events.
final class TouchGestureEngine {
    enum ScrollPhase { case began, changed, ended, cancelled }
    enum Action {
        case cursor(CGPoint)
        case click(CGPoint, count: Int, right: Bool)
        case mouseDown(CGPoint), mouseDrag(CGPoint), mouseUp(CGPoint)
        case scroll(CGPoint, anchor: CGPoint, phase: ScrollPhase)
        case momentum(CGPoint, anchor: CGPoint)
        case stopMomentum
        case prepareZoom(CGPoint), zoom(Double), endZoom
    }
    private enum State { case idle, onePending, scrolling, dragging, twoPending, twoScrolling, pinching }
    private enum Axis { case undecided, horizontal, vertical, free }
    private struct Sample { let time: UInt64; let point: CGPoint }
    private var state: State = .idle
    private var start = CGPoint.zero
    private var last = CGPoint.zero
    private var anchor = CGPoint.zero
    private var downTime: UInt64 = 0
    private var lastTime: UInt64 = 0
    private var lastMotionTime: UInt64 = 0
    private var longPressArmed = true
    private var suppressTap = false
    private var trackedIDs: [Int32] = []
    private var initialDistance: Double = 0
    private var lastDistance: Double = 0
    private var scrollDistanceBaseline: Double = 0
    private var axis: Axis = .undecided
    private var samples: [Sample] = []
    private var lastTapTime: UInt64?
    private var deferredFling: (velocity: CGPoint, anchor: CGPoint, time: UInt64)?
    private var lastTapPoint = CGPoint.zero
    private(set) var viewport = CGSize(width: 1, height: 1)

    func cancel() -> [Action] {
        var actions: [Action] = [.stopMomentum, .endZoom]
        if state == .dragging { actions.append(.mouseUp(normalized(last))) }
        if state == .scrolling || state == .twoScrolling {
            actions.append(.scroll(.zero, anchor: anchor, phase: .cancelled))
        }
        state = .idle
        trackedIDs = []
        samples = []
        deferredFling = nil
        lastTapTime = nil
        suppressTap = true
        axis = .undecided
        return actions
    }

    func process(_ frame: TouchInputFrame, preferences: TouchPreferences,
                 doubleClickMilliseconds: Double, braking: Bool) -> [Action] {
        if frame.phase == .cancel { return cancel() }
        if state != .idle, frame.timestampMs < lastTime { return cancel() }
        let dimensions = CGSize(width: frame.viewportWidthDp, height: frame.viewportHeightDp)
        guard dimensions.width > 0, dimensions.height > 0 else { return cancel() }
        if state != .idle, dimensions != viewport { return cancel() }
        viewport = dimensions
        lastTime = frame.timestampMs
        let contacts = frame.contacts.sorted { $0.id < $1.id }
        guard !contacts.isEmpty else { return cancel() }
        switch frame.phase {
        case .down:
            let previousTap = state == .idle && !braking ? lastTapTime : nil
            let previousTapPoint = lastTapPoint
            var actions = cancel()
            lastTapTime = previousTap
            lastTapPoint = previousTapPoint
            viewport = dimensions
            lastTime = frame.timestampMs
            actions += startOne(contacts[0], time: frame.timestampMs, suppressTap: braking)
            return actions
        case .pointerDown:
            guard state == .onePending || state == .scrolling || state == .dragging,
                  trackedIDs.count == 1, contacts.count == 2,
                  contacts.contains(where: { $0.id == trackedIDs[0] }) else { return [] }
            deferredFling = nil
            var actions: [Action] = [.stopMomentum]
            if state == .dragging { actions.append(.mouseUp(normalized(last))) }
            if state == .scrolling || state == .twoScrolling {
                actions.append(.scroll(.zero, anchor: anchor, phase: .ended))
            }
            actions += startTwo(contacts, time: frame.timestampMs)
            return actions
        case .move:
            if contacts.count == 2 {
                if trackedIDs != contacts.map(\.id) || !(state == .twoPending || state == .twoScrolling || state == .pinching) {
                    guard state != .idle else { return [] }
                    var actions = cancel()
                    actions += startTwo(contacts, time: frame.timestampMs)
                    return actions
                }
                return moveTwo(contacts, time: frame.timestampMs, preferences: preferences)
            }
            guard state != .idle else { return [] }
            if trackedIDs != [contacts[0].id] {
                var actions = cancel()
                actions += startOne(contacts[0], time: frame.timestampMs, suppressTap: true)
                return actions
            }
            return moveOne(contacts[0], time: frame.timestampMs, preferences: preferences)
        case .pointerUp:
            guard state == .twoPending || state == .twoScrolling || state == .pinching,
                  contacts.map(\.id) == trackedIDs, trackedIDs.contains(frame.changedPointerID) else { return [] }
            let releaseVelocity = state == .twoScrolling && frame.timestampMs >= lastMotionTime && frame.timestampMs - lastMotionTime <= 60
                ? estimatedVelocity().map { locked($0, total: subtract(last, start), enabled: preferences.axisLock) } : nil
            let releaseAnchor = anchor
            var actions: [Action] = [.endZoom, .stopMomentum]
            if state == .twoScrolling { actions.append(.scroll(.zero, anchor: anchor, phase: .ended)) }
            if state == .dragging { actions.append(.mouseUp(normalized(last))) }
            lastTapTime = nil
            if let remaining = contacts.first(where: { $0.id != frame.changedPointerID }) {
                actions += startOne(remaining, time: frame.timestampMs, suppressTap: true)
                if let releaseVelocity, length(releaseVelocity) >= 60, preferences.momentum != .off {
                    deferredFling = (releaseVelocity, releaseAnchor, frame.timestampMs)
                }
            } else { actions += cancel() }
            return actions
        case .up:
            return endOne(contacts[0], time: frame.timestampMs, preferences: preferences,
                          doubleClickMilliseconds: doubleClickMilliseconds)
        case .cancel: return cancel()
        }
    }

    private func startOne(_ contact: TouchContact, time: UInt64, suppressTap: Bool) -> [Action] {
        start = dp(contact); last = start; anchor = normalized(start)
        downTime = time; lastTime = time; lastMotionTime = time
        state = .onePending; trackedIDs = [contact.id]
        longPressArmed = !suppressTap; self.suppressTap = suppressTap
        axis = .undecided; samples = [Sample(time: time, point: start)]
        return [.stopMomentum, .cursor(anchor)]
    }

    private func startTwo(_ contacts: [TouchContact], time: UInt64) -> [Action] {
        let a = dp(contacts[0]), b = dp(contacts[1])
        start = midpoint(a, b); last = start; anchor = normalized(start)
        initialDistance = max(1, distance(a, b)); lastDistance = initialDistance
        scrollDistanceBaseline = initialDistance
        state = .twoPending; trackedIDs = contacts.map(\.id)
        lastTapTime = nil; suppressTap = true; longPressArmed = false
        axis = .undecided; samples = [Sample(time: time, point: start)]
        lastMotionTime = time
        return [.prepareZoom(anchor)]
    }

    private func moveOne(_ contact: TouchContact, time: UInt64, preferences: TouchPreferences) -> [Action] {
        guard state == .onePending || state == .scrolling || state == .dragging else { return [] }
        let point = dp(contact), displacement = subtract(point, start)
        let travelled = length(displacement)
        if travelled > 3 { deferredFling = nil }
        let heldLong = longPressArmed && time >= downTime && time - downTime >= 500
        if travelled > 3, !heldLong { longPressArmed = false }
        var actions: [Action] = []
        switch state {
        case .onePending:
            if travelled >= 8 {
                lastTapTime = nil
                if preferences.mode == .desktop || heldLong {
                    state = .dragging
                    actions += [.mouseDown(normalized(start)), .mouseDrag(normalized(point))]
                } else {
                    state = .scrolling
                    axis = chooseAxis(displacement, enabled: preferences.axisLock)
                    actions.append(.scroll(locked(displacement, total: displacement, enabled: preferences.axisLock), anchor: anchor, phase: .began))
                }
            }
        case .scrolling:
            actions.append(.scroll(locked(subtract(point, last), total: displacement, enabled: preferences.axisLock), anchor: anchor, phase: .changed))
        case .dragging: actions.append(.mouseDrag(normalized(point)))
        default: break
        }
        record(point, time: time)
        last = point
        return actions
    }

    private func moveTwo(_ contacts: [TouchContact], time: UInt64, preferences: TouchPreferences) -> [Action] {
        let a = dp(contacts[0]), b = dp(contacts[1])
        let point = midpoint(a, b), gap = max(1, distance(a, b))
        let travel = subtract(point, start), pan = length(travel)
        let pinch = abs(gap - initialDistance)
        let pinchReady = pinch >= 8 && abs(log(gap / initialDistance)) >= log(1.04)
        var actions: [Action] = []
        switch state {
        case .twoPending:
            if pinchReady && (pan < 8 || pinch * 0.5 >= pan) {
                state = .pinching
                actions.append(.zoom(log(gap / initialDistance)))
            } else if pan >= 8 {
                state = .twoScrolling
                scrollDistanceBaseline = gap
                axis = chooseAxis(travel, enabled: preferences.axisLock)
                actions.append(.scroll(locked(travel, total: travel, enabled: preferences.axisLock), anchor: anchor, phase: .began))
            }
        case .twoScrolling:
            let scaleTravel = abs(gap - scrollDistanceBaseline)
            if scaleTravel >= 12 && abs(log(gap / scrollDistanceBaseline)) >= log(1.08) {
                actions.append(.scroll(.zero, anchor: anchor, phase: .ended))
                state = .pinching
                samples = []
                actions.append(.zoom(log(gap / scrollDistanceBaseline)))
            } else {
                actions.append(.scroll(locked(subtract(point, last), total: travel, enabled: preferences.axisLock), anchor: anchor, phase: .changed))
            }
        case .pinching:
            actions.append(.zoom(log(gap / lastDistance)))
        default: break
        }
        if state != .pinching { record(point, time: time) }
        last = point; lastDistance = gap
        return actions
    }

    private func endOne(_ contact: TouchContact, time: UInt64, preferences: TouchPreferences,
                        doubleClickMilliseconds: Double) -> [Action] {
        let point = dp(contact)
        var actions: [Action] = []
        switch state {
        case .onePending:
            if let fling = deferredFling, preferences.momentum != .off, time >= fling.time,
               time - fling.time <= 60, distance(point, start) <= 3 {
                actions.append(.momentum(fling.velocity, anchor: fling.anchor))
            } else if !suppressTap, distance(point, start) < 8 {
                let right = longPressArmed && time >= downTime && time - downTime >= 500
                if right { actions.append(.click(normalized(point), count: 1, right: true)); lastTapTime = nil }
                else {
                    let doubleTap = lastTapTime.map { time >= $0 && Double(time - $0) <= doubleClickMilliseconds && distance(point, lastTapPoint) <= 12 } ?? false
                    actions.append(.click(normalized(point), count: doubleTap ? 2 : 1, right: false))
                    lastTapTime = doubleTap ? nil : time; lastTapPoint = point
                }
            }
        case .dragging: actions.append(.mouseUp(normalized(point)))
        case .scrolling, .twoScrolling:
            actions.append(.scroll(.zero, anchor: anchor, phase: .ended))
            if preferences.momentum != .off, time >= lastMotionTime, time - lastMotionTime <= 60,
               let velocity = estimatedVelocity(), length(velocity) >= 60 {
                actions.append(.momentum(locked(velocity, total: subtract(last, start), enabled: preferences.axisLock), anchor: anchor))
            }
            lastTapTime = nil
        case .pinching, .twoPending: actions.append(.endZoom); lastTapTime = nil
        case .idle: break
        }
        state = .idle; trackedIDs = []; samples = []; deferredFling = nil; longPressArmed = false
        return actions
    }

    private func record(_ point: CGPoint, time: UInt64) {
        if distance(point, last) >= 0.25 { lastMotionTime = time }
        if samples.last?.time == time { samples.removeLast() }
        samples.append(Sample(time: time, point: point))
        samples.removeAll { time >= $0.time && time - $0.time > 80 }
    }

    private func estimatedVelocity() -> CGPoint? {
        guard samples.count >= 2, let first = samples.first, let end = samples.last, end.time > first.time else { return nil }
        let times = samples.map { Double($0.time - first.time) / 1000 }
        let meanT = times.reduce(0, +) / Double(times.count)
        let meanX = samples.map { $0.point.x }.reduce(0, +) / CGFloat(samples.count)
        let meanY = samples.map { $0.point.y }.reduce(0, +) / CGFloat(samples.count)
        var denominator = 0.0, numeratorX = 0.0, numeratorY = 0.0
        for (index, sample) in samples.enumerated() {
            let dt = times[index] - meanT
            denominator += dt * dt
            numeratorX += dt * Double(sample.point.x - meanX)
            numeratorY += dt * Double(sample.point.y - meanY)
        }
        guard denominator > 0.000001 else { return nil }
        let velocity = CGPoint(x: numeratorX / denominator, y: numeratorY / denominator)
        let recentIndex = samples.firstIndex(where: { end.time - $0.time <= 25 }) ?? 0
        let recent = samples[recentIndex]
        let tail = subtract(end.point, recent.point)
        if length(tail) > 0.5 && velocity.x * tail.x + velocity.y * tail.y <= 0 { return nil }
        return velocity
    }

    private func chooseAxis(_ delta: CGPoint, enabled: Bool) -> Axis {
        guard enabled else { return .free }
        if abs(delta.y) >= 1.5 * abs(delta.x) { return .vertical }
        if abs(delta.x) >= 1.5 * abs(delta.y) { return .horizontal }
        return .free
    }
    private func locked(_ delta: CGPoint, total: CGPoint, enabled: Bool) -> CGPoint {
        guard enabled else { return delta }
        if axis == .vertical && abs(total.x) > 12 && abs(total.x) > abs(total.y) * 0.75 { axis = .free }
        if axis == .horizontal && abs(total.y) > 12 && abs(total.y) > abs(total.x) * 0.75 { axis = .free }
        switch axis {
        case .horizontal: return CGPoint(x: delta.x, y: 0)
        case .vertical: return CGPoint(x: 0, y: delta.y)
        default: return delta
        }
    }
    private func dp(_ c: TouchContact) -> CGPoint { CGPoint(x: c.x * viewport.width, y: c.y * viewport.height) }
    private func normalized(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x / viewport.width, y: p.y / viewport.height) }
    private func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
    private func subtract(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
    private func distance(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(Double(a.x - b.x), Double(a.y - b.y)) }
    private func length(_ p: CGPoint) -> Double { hypot(Double(p.x), Double(p.y)) }
}
