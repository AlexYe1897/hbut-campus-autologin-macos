// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HBUTCampusAutoLogin",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CampusAutoLogin", targets: ["CampusAutoLogin"])
    ],
    targets: [
        .executableTarget(
            name: "CampusAutoLogin",
            path: "Sources",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Security"),
                .linkedFramework("LocalAuthentication"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOKit")
            ]
        )
    ],
    swiftLanguageVersions: [.v5]
)
