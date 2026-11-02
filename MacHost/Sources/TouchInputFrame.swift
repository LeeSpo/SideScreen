import Foundation

enum TouchPhase: UInt8 {
    case down = 0, move = 1, up = 2, cancel = 3, pointerDown = 4, pointerUp = 5
}

struct TouchContact {
    let id: Int32
    let x: Double
    let y: Double
    let tool: UInt8
}

/// Raw tablet view coordinates, before the display's mirror transform.
struct TouchInputFrame {
    let sessionToken: UInt64
    let sequence: UInt64
    let timestampMs: UInt64
    let phase: TouchPhase
    let changedPointerID: Int32
    let viewportWidthDp: Double
    let viewportHeightDp: Double
    let contacts: [TouchContact]

    static func decode(_ data: Data) -> TouchInputFrame? {
        guard data.count >= 38 else { return nil }
        func u64(_ offset: Int) -> UInt64 { data.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self)) } }
        func i32(_ offset: Int) -> Int32 { data.withUnsafeBytes { Int32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: Int32.self)) } }
        func f32(_ offset: Int) -> Double { Double(Float(bitPattern: data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) })) }
        guard let phase = TouchPhase(rawValue: data[24]) else { return nil }
        let count = Int(data[37])
        guard count <= 2, data.count == 38 + count * 13 else { return nil }
        let width = f32(29), height = f32(33)
        guard width.isFinite, height.isFinite, width > 0, height > 0, width <= 100_000, height <= 100_000 else { return nil }
        var contacts: [TouchContact] = []
        for index in 0..<count {
            let offset = 38 + index * 13
            let x = f32(offset + 4), y = f32(offset + 8)
            guard x.isFinite, y.isFinite, abs(x) <= 10, abs(y) <= 10 else { return nil }
            contacts.append(TouchContact(id: i32(offset), x: x, y: y, tool: data[offset + 12]))
        }
        guard Set(contacts.map(\.id)).count == count else { return nil }
        let changed = i32(25)
        switch phase {
        case .cancel: guard count == 0 else { return nil }
        case .down, .up: guard count == 1, contacts.first?.id == changed else { return nil }
        case .pointerDown, .pointerUp: guard count == 2, contacts.contains(where: { $0.id == changed }) else { return nil }
        case .move: guard count > 0 else { return nil }
        }
        return TouchInputFrame(sessionToken: u64(0), sequence: u64(8), timestampMs: u64(16), phase: phase, changedPointerID: changed, viewportWidthDp: width, viewportHeightDp: height, contacts: contacts)
    }
}
