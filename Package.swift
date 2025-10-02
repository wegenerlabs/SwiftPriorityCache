// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "SwiftPriorityCache",
    platforms: [
        .iOS(.v16), .macOS(.v13), .tvOS(.v16), .watchOS(.v9),
    ],
    products: [
        .library(name: "SwiftPriorityCache", targets: ["SwiftPriorityCache"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "SwiftPriorityCache",
            dependencies: [
                .product(name: "OrderedCollections", package: "swift-collections"),
            ]
        ),
        .testTarget(
            name: "SwiftPriorityCacheTests",
            dependencies: [
                "SwiftPriorityCache",
            ]
        ),
    ]
)
