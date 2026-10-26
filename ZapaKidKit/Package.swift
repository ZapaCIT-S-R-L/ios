// swift-tools-version: 6.0
// The app's logic (API clients, session, later the libsignal crypto) without UI, so it is easy to test and review.
import PackageDescription

let package = Package(
    name: "ZapaKidKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ZapaKidKit", targets: ["ZapaKidKit"]),
    ],
    targets: [
        .target(name: "ZapaKidKit"),
    ]
)
