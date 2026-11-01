import Foundation
import Security

/// API 키 같은 비밀값 저장소. 앱은 사용자가 직접 입력한 키만 저장하며 다른 앱의 키를 읽지 않습니다.
protocol SecretStore: AnyObject {
    func read(_ key: String) -> String?
    func write(_ key: String, value: String) throws
    func delete(_ key: String)
}

/// macOS 키체인(이 앱 전용 항목). App Sandbox 안에서도 동작합니다.
final class KeychainSecretStore: SecretStore {
    private let service: String

    init(service: String = "io.github.pgup3017.Condux") {
        self.service = service
    }

    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    func read(_ key: String) -> String? {
        var query = query(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    func write(_ key: String, value: String) throws {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query(key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query(key)
            attributes[kSecValueData as String] = data
            let added = SecItemAdd(attributes as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    func delete(_ key: String) {
        SecItemDelete(query(key) as CFDictionary)
    }
}

struct KeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "알 수 없는 키체인 오류"
        return "키체인 저장 실패 (\(status)): \(message)"
    }
}

/// 테스트용. 메모리에만 둡니다.
final class InMemorySecretStore: SecretStore {
    private var values: [String: String] = [:]
    func read(_ key: String) -> String? { values[key] }
    func write(_ key: String, value: String) { values[key] = value }
    func delete(_ key: String) { values[key] = nil }
}
