// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CampusGuardKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        // Tag protocol, ntfy link, Find My client. Foundation only, fully unit-tested.
        .library(name: "TagKit", targets: ["TagKit"]),
        // SwiftUI screens, app model and phone services (notifications, location, siren).
        .library(name: "CampusGuardUI", targets: ["CampusGuardUI"]),
    ],
    targets: [
        .target(name: "TagKit"),
        .target(name: "CampusGuardUI", dependencies: ["TagKit"]),
        .testTarget(name: "TagKitTests", dependencies: ["TagKit"]),
    ],
    swiftLanguageModes: [.v6]
)
