// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SSCOMKit",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "SSCOMKit", targets: ["SSCOMKit"])
    ],
    targets: [
        .target(
            name: "SSCOMKit",
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ],
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .testTarget(name: "SSCOMKitTests", dependencies: ["SSCOMKit"]),
    ],
    swiftLanguageModes: [.v6]
)
