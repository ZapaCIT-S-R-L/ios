// swift-tools-version: 6.0
// ZapaCalls: 1:1 and group voice calls (Cloudflare Realtime SFU), end-to-end encrypted per audio frame.
// Logic and, later, the call screens; the app wires in the libsignal key sealer and CallKit.
import PackageDescription

let package = Package(
    name: "ZapaCalls",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ZapaCalls", targets: ["ZapaCalls"]),
    ],
    targets: [
        .target(name: "ZapaCalls"),
    ]
)
