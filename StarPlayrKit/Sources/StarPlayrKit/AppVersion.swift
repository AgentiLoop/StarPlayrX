//
//  AppVersion.swift
//  StarPlayrKit
//
//  Copyright © 2026 Todd Bruss. All rights reserved.
//

import Foundation

public enum AppVersion {
    /// "v1.1.8" from the app's bundle; Debug builds add "-dev".
    public static let string: String = {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        #if DEBUG
        return "v\(v)-dev"
        #else
        return "v\(v)"
        #endif
    }()
}
