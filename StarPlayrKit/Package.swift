// swift-tools-version:5.9
//
//  StarPlayrKit — the code StarPlayrX shares between macOS (StarPlayrXMac) and iOS/iPadOS
//  (StarPlayrXiOS): Xtra/live client, models, lyrics, Keychain, EQ analysis. No AppKit/UIKit.
//
import PackageDescription

let package = Package(
    name: "StarPlayrKit",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [
        .library(name: "StarPlayrKit", targets: ["StarPlayrKit"]),
    ],
    targets: [
        .target(name: "StarPlayrKit"),
    ]
)
