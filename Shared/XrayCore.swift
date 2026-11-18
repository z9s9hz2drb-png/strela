import Foundation
import LibXray

struct XrayError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Thin wrapper over libXray's single entry point `Invoke(requestJSON)` (API version 3).
/// https://github.com/XTLS/libXray — every call is a JSON envelope `{apiVersion, method, payload}`.
enum XrayCore {
    @discardableResult
    static func invoke(_ method: String, payload: JSONObject = [:]) throws -> Any? {
        let request: JSONObject = ["apiVersion": 3, "method": method, "payload": payload]
        let requestJSON = try JSONUtil.string(request)
        // gomobile export: NSString* LibXrayInvoke(NSString*). `?? ""` keeps this compiling
        // whether the generated header marks the result nullable or not.
        let responseJSON: String = LibXrayInvoke(requestJSON) ?? ""
        guard let response = JSONUtil.object(responseJSON) else {
            throw XrayError(message: "libXray: некорректный ответ")
        }
        if (response["success"] as? Bool) == true {
            return response["data"]
        }
        throw XrayError(message: (response["error"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "libXray: ошибка \(method)")
    }

    static func run(configJSON: String) throws {
        try invoke("runXray", payload: ["xrayJson": configJSON])
    }

    static func stop() {
        _ = try? invoke("stopXray")
    }

    static var isRunning: Bool {
        ((try? invoke("getXrayState")) as? JSONObject)?["running"] as? Bool ?? false
    }

    /// Builds (but does not start) an Xray instance: validates routing, geo codes, outbounds.
    static func test(configJSON: String) throws {
        try invoke("testXray", payload: ["xrayJson": configJSON])
    }

    static func version() -> String {
        ((try? invoke("xrayVersion")) as? JSONObject)?["version"] as? String ?? "—"
    }

    static func freePorts(_ count: Int) throws -> [Int] {
        guard count > 0 else { return [] }
        let data = try invoke("getFreePorts", payload: ["count": count]) as? JSONObject
        let ports = (data?["ports"] as? [Any])?.compactMap { JSONUtil.int($0) } ?? []
        guard ports.count == count else { throw XrayError(message: "Не удалось выделить локальные порты") }
        return ports
    }

    /// Converts share links / Base64 / Xray JSON into outbounds (validated by the bundled core).
    static func convertLinks(_ text: String, ageSecretKey: String? = nil) throws -> [JSONObject] {
        var payload: JSONObject = ["text": text]
        if let ageSecretKey { payload["age"] = ["secretKey": ageSecretKey] }
        let data = try invoke("convertShareLinksToXrayJson", payload: payload) as? JSONObject
        return data?["outbounds"] as? [JSONObject] ?? []
    }

    /// Generates share links for outbounds (used for "copy link" of JSON-only servers).
    static func shareLinks(for outbounds: [JSONObject]) throws -> String {
        let json = try JSONUtil.string(["outbounds": outbounds])
        let data = try invoke("convertXrayJsonToShareLinks", payload: ["xrayJson": json]) as? JSONObject
        return data?["links"] as? String ?? ""
    }

    /// Unwraps an age-encrypted subscription body; plaintext is returned unchanged.
    static func decodeSubscription(_ text: String, ageSecretKey: String?) throws -> String {
        var payload: JSONObject = ["text": text]
        if let ageSecretKey { payload["age"] = ["secretKey": ageSecretKey] }
        let data = try invoke("decodeSubscriptionText", payload: payload) as? JSONObject
        return data?["text"] as? String ?? text
    }

    static func generateAgeKeyPair() throws -> (secretKey: String, publicKey: String) {
        let data = try invoke("generateAgeKeyPair", payload: ["keyType": "x25519"]) as? JSONObject
        guard let secret = data?["secretKey"] as? String, let pub = data?["publicKey"] as? String else {
            throw XrayError(message: "Не удалось создать ключи age")
        }
        return (secret, pub)
    }
}
