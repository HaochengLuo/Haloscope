// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Haloscope",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Haloscope", targets: ["Haloscope"])],
    targets: [
        .executableTarget(name: "Haloscope", path: "Haloscope"),
        .testTarget(name: "HaloscopeTests", dependencies: ["Haloscope"], path: "HaloscopeTests", resources: [.process("Fixtures")])
    ]
)
