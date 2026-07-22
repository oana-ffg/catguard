import Foundation
import Security

struct KeychainStore {
    enum Error: LocalizedError {
        case unexpectedStatus(OSStatus)
        case invalidStoredValue

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                "Keychain operation failed (OSStatus \(status))."
            case .invalidStoredValue:
                "The rescue phrase stored in Keychain is not valid UTF-8."
            }
        }
    }

    private let service: String
    private let account: String

    init(service: String = "com.oanaffg.CatGuard", account: String = "rescue-phrase") {
        self.service = service
        self.account = account
    }

    func read() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw Error.unexpectedStatus(status)
        }
        guard let data = result as? Data,
            let value = String(data: data, encoding: .utf8)
        else {
            throw Error.invalidStoredValue
        }
        return value
    }

    func write(_ value: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw Error.unexpectedStatus(updateStatus)
        }

        var newItem = query
        for (key, value) in attributes {
            newItem[key] = value
        }
        let addStatus = SecItemAdd(newItem as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw Error.unexpectedStatus(addStatus)
        }
    }
}
