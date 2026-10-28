// swift-tools-version: 6.0
// ZapaChat: end-to-end encrypted family chat (services/chat). Logic without UI; the libsignal sealer comes from
// the app (MessageSealer).
import PackageDescription

let package = Package(
    name: "ZapaChat",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ZapaChat", targets: ["ZapaChat"]),
    ],
    targets: [
        .target(name: "ZapaChat"),
    ]
)
