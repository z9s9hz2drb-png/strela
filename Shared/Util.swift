import Foundation

typealias JSONObject = [String: Any]

/// Empty JSON object, handy inside heterogeneous dictionary literals.
let emptyObject: JSONObject = [:]

enum JSONUtil {
    static func object(_ text: String) -> JSONObject? {
        any(text) as? JSONObject
    }

    static func any(_ text: String) -> Any? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    static func string(_ value: Any, pretty: Bool = false) throws -> String {
        var options: JSONSerialization.WritingOptions = [.withoutEscapingSlashes]
        if pretty {
            options.insert(.prettyPrinted)
            options.insert(.sortedKeys)
        }
        let data = try JSONSerialization.data(withJSONObject: value, options: options)
        return String(decoding: data, as: UTF8.self)
    }

    static func int(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber:
            return number.intValue
        case let text as String:
            return Int(text.trimmingCharacters(in: .whitespaces))
        default:
            return nil
        }
    }

    static func text(_ value: Any?) -> String? {
        switch value {
        case let text as String:
            return text
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }
}

enum Base64 {
    /// Decodes standard and URL-safe base64, with or without padding and line breaks.
    static func decode(_ input: String) -> Data? {
        var text = input.components(separatedBy: .whitespacesAndNewlines).joined()
        text = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while text.hasSuffix("=") { text.removeLast() }
        guard !text.isEmpty else { return nil }
        let remainder = text.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { text += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: text)
    }

    static func decodeString(_ input: String) -> String? {
        guard let data = decode(input) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func encode(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
    }
}

extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

extension KeyedDecodingContainer {
    /// Decodes a value if present and valid, otherwise returns the fallback (keeps old state files readable).
    func value<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}
