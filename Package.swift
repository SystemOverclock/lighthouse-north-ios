// swift-tools-version:5.9
// SDK iOS nativo independente (codinome — nome de publicação SPM/CocoaPods
// pendente do dono). Sem dependências externas: URLSession, UNUserNotifications
// e Keychain da plataforma; Firebase é provider injetável do HOST (o SDK não
// embute — decisão 3.2, paridade com client-flutter/client-android).
//
// platforms: iOS 13+ (UNUserNotifications 10+, Swift concurrency 13+) e
// macOS 12+ APENAS para `swift test` rodar em Mac local/CI — os caminhos de
// UIKit são gateados por canImport(UIKit).
import PackageDescription

let package = Package(
    name: "LighthouseNorthClient",
    platforms: [
        .iOS(.v13),
        .macOS(.v12),
    ],
    products: [
        .library(name: "LighthouseNorthClient", targets: ["LighthouseNorthClient"]),
    ],
    targets: [
        .target(
            name: "LighthouseNorthClient",
            path: "Sources/LighthouseNorth"
        ),
        .testTarget(
            name: "LighthouseNorthClientTests",
            dependencies: ["LighthouseNorthClient"],
            path: "Tests/LighthouseNorthTests"
        ),
    ]
)
