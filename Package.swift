// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LibraryStore",
    platforms: [.macOS("27.2")],
    products: [.library(name: "LibraryStore", targets: ["LibraryStore"])],
    targets: [
        .target(name: "LibraryStore"),
        .testTarget(name: "LibraryStoreTests", dependencies: ["LibraryStore"])
    ],
    swiftLanguageModes: [.v6]
)
