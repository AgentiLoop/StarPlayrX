//
//  Keychain.swift
//  StarPlayrXMac
//
//  Created by Todd Bruss on 10/31/26.
//  Modified by Todd Bruss on 11/2/26.
//  Copyright © 2026 Todd Bruss. All rights reserved.
//

import Foundation
import Security

/// Stores the SiriusXM credentials in the user's Keychain (never in UserDefaults or on disk in plain text).
/// Uses the data protection keychain: access is granted by the app's team/keychain access group, not by a
/// per-binary ACL, so rebuilt or updated builds don't trigger the "wants to use your confidential information" prompt.
public enum Keychain {
    private static let service = "com.starplayrx.mac.credentials"

    public static func save(user: String, pass: String) {
        delete()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: user,
            kSecValueData as String: Data(pass.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecUseDataProtectionKeychain as String: true
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    public static func load() -> (user: String, pass: String)? {
        if let creds = load(dataProtection: true) { return creds }
        // One-time migration from the legacy login keychain (may prompt one last time).
        guard let legacy = load(dataProtection: false) else { return nil }
        save(user: legacy.user, pass: legacy.pass)
        delete(dataProtection: false)
        return legacy
    }

    public static func delete() {
        delete(dataProtection: true)
    }

    private static func load(dataProtection: Bool) -> (user: String, pass: String)? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain as String: dataProtection
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let dict = item as? [String: Any],
              let user = dict[kSecAttrAccount as String] as? String,
              let data = dict[kSecValueData as String] as? Data,
              let pass = String(data: data, encoding: .utf8)
        else { return nil }
        return (user, pass)
    }

    private static func delete(dataProtection: Bool) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: dataProtection
        ]
        SecItemDelete(query as CFDictionary)
    }
}
