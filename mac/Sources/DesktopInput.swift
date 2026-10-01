import AppKit
import ApplicationServices

/// Desktop events use Quartz's top-left display coordinates, matching the VR screen UVs.
final class DesktopInput {
    static let shared = DesktopInput()
    var trusted: Bool { AXIsProcessTrusted() }
    private let lock = NSLock()
    private var position = CGPoint.zero
    private var held = Set<Bool>()
    private let source = CGEventSource(stateID: .combinedSessionState)

    func requestTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func move(toNormalized p: CGPoint) {
        lock.lock(); defer { lock.unlock() }
        guard trusted, p.x.isFinite, p.y.isFinite else { return }
        let bounds = CGDisplayBounds(CGMainDisplayID())
        position = CGPoint(x: bounds.minX + min(1, max(0, p.x)) * max(0, bounds.width - 1),
                           y: bounds.minY + min(1, max(0, p.y)) * max(0, bounds.height - 1))
        let right = held.contains(true)
        let kind: CGEventType = right ? .rightMouseDragged : (held.contains(false) ? .leftMouseDragged : .mouseMoved)
        CGEvent(mouseEventSource: source, mouseType: kind, mouseCursorPosition: position,
                mouseButton: right ? .right : .left)?.post(tap: .cghidEventTap)
    }

    func button(_ right: Bool, down: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard trusted, down != held.contains(right) else { return }
        if down { held.insert(right) } else { held.remove(right) }
        emitButton(right, down: down, clicks: 1)
    }

    private func emitButton(_ right: Bool, down: Bool, clicks: Int64) {
        let kind: CGEventType = right ? (down ? .rightMouseDown : .rightMouseUp) : (down ? .leftMouseDown : .leftMouseUp)
        let event = CGEvent(mouseEventSource: source, mouseType: kind, mouseCursorPosition: position,
                            mouseButton: right ? .right : .left)
        event?.setIntegerValueField(.mouseEventClickState, value: clicks)
        event?.post(tap: .cghidEventTap)
    }

    func doubleClick(_ right: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        guard trusted, held.isEmpty else { return }
        for count: Int64 in [1, 2] {
            emitButton(right, down: true, clicks: count)
            emitButton(right, down: false, clicks: count)
        }
    }

    /// Call when the desktop panel closes or tracking disconnects to avoid stuck drags.
    func releaseAll() {
        lock.lock(); defer { lock.unlock() }
        for right in held { emitButton(right, down: false, clicks: 1) }
        held.removeAll()
    }

    func scroll(dx: Int32, dy: Int32) {
        lock.lock(); defer { lock.unlock() }
        guard trusted, dx != 0 || dy != 0 else { return }
        CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                wheel1: dy, wheel2: dx, wheel3: 0)?.post(tap: .cghidEventTap)
    }

    func type(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        guard trusted else { return }
        // Character chunks keep surrogate pairs and composed characters intact.
        for character in text {
            let units = Array(String(character).utf16)
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                units.withUnsafeBufferPointer { buffer in
                    event?.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress!)
                }
                event?.post(tap: .cghidEventTap)
            }
        }
    }

    func key(_ code: CGKeyCode) {
        lock.lock(); defer { lock.unlock() }
        guard trusted else { return }
        for down in [true, false] {
            CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)?.post(tap: .cghidEventTap)
        }
    }
}
