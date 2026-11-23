import CryptoKit
import Security

public struct SessionKey: Sendable {
    public let id: [UInt8]
    let keyBytes: [UInt8]

    public static func random() -> SessionKey {
        var id = [UInt8](repeating: 0, count: 16)
        var key = [UInt8](repeating: 0, count: 32)
        let idStatus = SecRandomCopyBytes(kSecRandomDefault, id.count, &id)
        precondition(idStatus == errSecSuccess, "Failed to generate session ID")
        let keyStatus = SecRandomCopyBytes(kSecRandomDefault, key.count, &key)
        precondition(keyStatus == errSecSuccess, "Failed to generate session key")
        return SessionKey(id: id, keyBytes: key)
    }

    public init(id: [UInt8], keyBytes: [UInt8]) {
        precondition(id.count == 16 && keyBytes.count == 32)
        self.id = id
        self.keyBytes = keyBytes
    }
}
