// swift-tools-version:5.3
import PackageDescription

let package = Package(
    name: "TreeSitterJai",
    products: [
        .library(name: "TreeSitterJai", targets: ["TreeSitterJai"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter", from: "0.8.0"),
    ],
    targets: [
        .target(
            name: "TreeSitterJai",
            dependencies: [],
            path: ".",
            sources: [
                "src/parser.c",
                // NOTE: if your language has an external scanner, add it here.
            ],
            resources: [
                .copy("queries")
            ],
            publicHeadersPath: "bindings/swift",
            cSettings: [.headerSearchPath("src")]
        ),
        .testTarget(
            name: "TreeSitterJaiTests",
            dependencies: [
                "SwiftTreeSitter",
                "TreeSitterJai",
            ],
            path: "bindings/swift/TreeSitterJaiTests"
        )
    ],
    cLanguageStandard: .c11
)
