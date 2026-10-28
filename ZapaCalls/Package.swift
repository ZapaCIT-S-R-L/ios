// swift-tools-version: 6.0
// ZapaCalls: 1:1 and group voice calls (Cloudflare Realtime SFU), end-to-end encrypted per audio frame.
// Logic and the call screens; the app wires in the libsignal key sealer and CallKit.
import PackageDescription

let package = Package(
    name: "ZapaCalls",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ZapaCalls", targets: ["ZapaCalls"]),
    ],
    targets: [
        // Localizable.xcstrings: RO, EN, DE (scripts/strings.js checks every string is translated).
        .target(name: "ZapaCalls", resources: [.process("Localizable.xcstrings")]),
    ]
)
