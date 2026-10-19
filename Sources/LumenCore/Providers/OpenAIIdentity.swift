import CryptoKit
import Foundation
import Security

enum OpenAIIdentity {
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ value: String) throws -> Data {
        let base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4)) else {
            throw ChatGPTAuthError.invalidIdentity
        }
        return data
    }

    static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ChatGPTAuthError.invalidIdentity
        }
        return base64URL(Data(bytes))
    }

    static func challenge(_ verifier: String) -> String { base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }

    static func validate(_ token: String, jwks: JSONValue, clientID: String, nonce: String?, now: Date = Date()) throws -> JSONValue {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else { throw ChatGPTAuthError.invalidIdentity }
        let header = try JSONDecoder().decode(JSONValue.self, from: decode(parts[0]))
        guard header["alg"]?.string == "RS256", let kid = header["kid"]?.string,
              let jwk = jwks["keys"]?.array?.first(where: { $0["kid"]?.string == kid && $0["kty"]?.string == "RSA" }),
              jwk["use"] == nil || jwk["use"]?.string == "sig",
              jwk["alg"] == nil || jwk["alg"]?.string == "RS256",
              let n = jwk["n"]?.string, let e = jwk["e"]?.string else { throw ChatGPTAuthError.invalidIdentity }
        let modulus = try decode(n)
        guard (256...1024).contains(modulus.count) else { throw ChatGPTAuthError.invalidIdentity }
        let keyData = der(0x30, integer(modulus) + integer(try decode(e)))
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPublic]
        guard let key = SecKeyCreateWithData(keyData as CFData, attributes as CFDictionary, nil),
              SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256,
                                    Data("\(parts[0]).\(parts[1])".utf8) as CFData, try decode(parts[2]) as CFData, nil) else {
            throw ChatGPTAuthError.invalidIdentity
        }
        let claims = try JSONDecoder().decode(JSONValue.self, from: decode(parts[1]))
        let audiences = claims["aud"]?.array?.compactMap(\.string) ?? claims["aud"]?.string.map { [$0] } ?? []
        let time = now.timeIntervalSince1970
        guard claims["iss"]?.string == "https://auth.openai.com", audiences.contains(clientID),
              audiences.count == 1 || claims["azp"]?.string == clientID,
              claims["azp"] == nil || claims["azp"]?.string == clientID,
              let expiry = claims["exp"]?.number, expiry > time - 5,
              let issued = claims["iat"]?.number, issued <= time + 5,
              (claims["nbf"]?.number ?? time) <= time + 5,
              let subject = claims["sub"]?.string, !subject.isEmpty,
              nonce == nil || claims["nonce"]?.string == nonce else { throw ChatGPTAuthError.invalidIdentity }
        return claims
    }

    private static func integer(_ bytes: Data) -> Data {
        var value = Data(bytes.drop(while: { $0 == 0 }))
        if value.first.map({ $0 >= 128 }) ?? true { value.insert(0, at: 0) }
        return der(0x02, value)
    }

    private static func der(_ tag: UInt8, _ data: Data) -> Data {
        var length = data.count
        var bytes: [UInt8] = []
        if length < 128 { bytes = [UInt8(length)] }
        else {
            while length > 0 { bytes.insert(UInt8(length & 255), at: 0); length >>= 8 }
            bytes.insert(128 | UInt8(bytes.count), at: 0)
        }
        return Data([tag] + bytes) + data
    }
}
