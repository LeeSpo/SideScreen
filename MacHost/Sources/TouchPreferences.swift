import Foundation

enum TouchMode: String, Codable, CaseIterable {
    case reading, desktop

    var title: String { self == .reading ? "Reading" : "Desktop" }
}

enum TouchMomentum: String, Codable, CaseIterable {
    case off, weak, standard

    var title: String {
        switch self {
        case .off: return "Off"
        case .weak: return "Weak"
        case .standard: return "Standard"
        }
    }
}

struct TouchPreferences: Codable, Equatable {
    var mode: TouchMode = .reading
    var followFinger = true
    var sensitivity: Double = 1
    var axisLock = true
    var momentum: TouchMomentum = .weak
    var diagnostics = false

    init() {}

    private enum CodingKeys: String, CodingKey {
        case mode, followFinger, sensitivity, axisLock, momentum, diagnostics
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        mode = (try? values.decode(TouchMode.self, forKey: .mode)) ?? .reading
        followFinger = (try? values.decode(Bool.self, forKey: .followFinger)) ?? true
        let storedSensitivity = (try? values.decode(Double.self, forKey: .sensitivity)) ?? 1
        sensitivity = storedSensitivity.isFinite ? min(2, max(0.5, storedSensitivity)) : 1
        axisLock = (try? values.decode(Bool.self, forKey: .axisLock)) ?? true
        momentum = (try? values.decode(TouchMomentum.self, forKey: .momentum)) ?? .weak
        diagnostics = (try? values.decode(Bool.self, forKey: .diagnostics)) ?? false
    }
}

enum TouchZoomMethod: String, Codable, CaseIterable {
    case automatic, commandWheel, controlWheel, optionWheel, shortcuts, disabled

    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .commandWheel: return "Command + Scroll"
        case .controlWheel: return "Control + Scroll"
        case .optionWheel: return "Option + Scroll"
        case .shortcuts: return "Custom Shortcuts"
        case .disabled: return "Disabled"
        }
    }
}

struct TouchZoomBinding: Codable, Equatable {
    var method: TouchZoomMethod = .automatic
    var zoomInShortcut = "cmd+="
    var zoomOutShortcut = "cmd+-"

    init() {}

    private enum CodingKeys: String, CodingKey {
        case method, zoomInShortcut, zoomOutShortcut
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        method = (try? values.decode(TouchZoomMethod.self, forKey: .method)) ?? .automatic
        zoomInShortcut = (try? values.decode(String.self, forKey: .zoomInShortcut)) ?? "cmd+="
        zoomOutShortcut = (try? values.decode(String.self, forKey: .zoomOutShortcut)) ?? "cmd+-"
    }
}
