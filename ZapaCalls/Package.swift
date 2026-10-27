// swift-tools-version: 6.0
// ZapaCalls: 1:1 and group voice calls (Cloudflare Realtime SFU), end-to-end encrypted per audio frame.
// Logic, WebRTC media and, later, the call screens; the app wires in the libsignal key sealer and CallKit.
import PackageDescription

let package = Package(
    name: "ZapaCalls",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ZapaCalls", targets: ["ZapaCalls"]),
    ],
    dependencies: [
        // LiveKit's WebRTC build (webrtc-sdk, BSD-3-Clause; the package itself is MIT): the only maintained SwiftPM
        // binary with the FrameCryptor (per-frame AES-GCM) API. Exact version; checksum pinned by the package.
        .package(url: "https://github.com/livekit/webrtc-xcframework.git", exact: "150.7871.04"),
    ],
    targets: [
        // Localizable.xcstrings: RO, EN, DE (scripts/strings.js checks every string is translated).
        .target(
            name: "ZapaCalls",
            dependencies: [.product(name: "LiveKitWebRTC", package: "webrtc-xcframework")],
            resources: [.process("Localizable.xcstrings")]
        ),
    ]
)
