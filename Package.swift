// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "cashew",
    platforms: [
        .macOS(.v12),
        .iOS(.v15),
        .watchOS(.v8),
        .tvOS(.v15)
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "cashew",
            targets: ["cashew"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.4"),
        .package(url: "https://github.com/adalinxx/ArrayTrie.git", from: "1.0.1"),
        .package(url: "https://github.com/apple/swift-crypto.git", "1.0.0" ..< "4.0.0"),
        .package(url: "https://github.com/swift-libp2p/swift-cid.git", from: "0.0.1"),
        .package(url: "https://github.com/swift-libp2p/swift-multicodec.git", from: "0.0.1"),
        .package(url: "https://github.com/swift-libp2p/swift-multihash.git", from: "0.0.1"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "cashew",
            dependencies: [
                .product(name: "Collections", package: "swift-collections"),
                .product(name: "ArrayTrie", package: "ArrayTrie"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "CID", package: "swift-cid"),
                .product(name: "Multicodec", package: "swift-multicodec"),
                .product(name: "Multihash", package: "swift-multihash")],
            exclude: ["Encryption/README.md"]),
        .testTarget(
            name: "cashewTests",
            dependencies: ["cashew"]
        ),
    ]
)
