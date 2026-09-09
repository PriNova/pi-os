// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PiOSMacNativeShell",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "pi-os-native-shell", targets: ["NativeShell"])],
    targets: [
        .target(name: "ShellCore"),
        .executableTarget(
            name: "NativeShell",
            dependencies: ["ShellCore"],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("Carbon")]
        ),
        .testTarget(name: "ShellCoreTests", dependencies: ["ShellCore"])
    ]
)
