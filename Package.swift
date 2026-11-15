// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BerLaunchpad",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "BerLaunchpad", targets: ["BerLaunchpad"])
    ],
    targets: [
        .executableTarget(
            name: "BerLaunchpad",
            path: "Sources/BerLaunchpad",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("UniformTypeIdentifiers")
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
