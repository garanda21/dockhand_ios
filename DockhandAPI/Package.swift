// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DockhandAPI",
    platforms: [
        .iOS(.v26),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "DockhandAPI",
            targets: ["DockhandAPI"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.12.0"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession", from: "1.3.0")
    ],
    targets: [
        .target(
            name: "DockhandAPI",
            dependencies: [
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession")
            ],
            path: "Sources/DockhandAPI"
        )
    ]
)
