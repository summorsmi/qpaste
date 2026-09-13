// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Qpaste",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Qpaste", targets: ["Qpaste"])],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "QpasteCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "Qpaste", dependencies: ["QpasteCore"]),
        .testTarget(name: "QpasteCoreTests", dependencies: ["QpasteCore"]),
        .testTarget(name: "QpasteTests", dependencies: ["Qpaste", "QpasteCore"])
    ],
    swiftLanguageModes: [.v5]
)
