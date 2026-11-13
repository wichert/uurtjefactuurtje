// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LibraryStore",
    platforms: [.macOS("27.0")],
    products: [.library(name: "LibraryStore", targets: ["LibraryStore"])],
    targets: [
        .target(name: "LibraryStore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "LibraryStoreTests", dependencies: ["LibraryStore"])
    ],
    swiftLanguageModes: [.v6]
)
