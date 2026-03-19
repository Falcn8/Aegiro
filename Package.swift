// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Aegiro",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AegiroCore", targets: ["AegiroCore"]),
        .executable(name: "aegiro-cli", targets: ["AegiroCLI"]),
        .executable(name: "AegiroApp", targets: ["AegiroApp"]),
    ],
    targets: [
        .target(
            name: "AegiroCore",
            dependencies: [
                // Required for cryptographic build and packaging
                .target(name: "Argon2C"),
                .target(name: "OQSWrapper"),
                .target(name: "OpenSSLShim"),
            ],
            linkerSettings: [
                .unsafeFlags(["-Xlinker","-force_load","-Xlinker","/opt/homebrew/lib/liboqs.a","-L/opt/homebrew/opt/openssl@3/lib","-lcrypto"], .when(configuration: .release))
            ]
        ),
        .executableTarget(
            name: "AegiroCLI",
            dependencies: ["AegiroCore"]
        ),
        .executableTarget(
            name: "AegiroApp",
            dependencies: ["AegiroCore"],
            exclude: ["Entitlements.plist"],
            resources: [
                .process("Resources/LandingHero.png"),
                .process("Resources/Fonts")
            ]
        ),
        .systemLibrary(
            name: "Argon2C",
            pkgConfig: "libargon2",
            providers: [
                .brew(["argon2"])
            ]
        ),
        .systemLibrary(
            name: "OQSWrapper",
            pkgConfig: "liboqs",
            providers: [
                .brew(["liboqs"])
            ]
        ),
        .systemLibrary(
            name: "OpenSSLShim",
            pkgConfig: "openssl",
            providers: [
                .brew(["openssl@3"])
            ]
        ),
        .testTarget(
            name: "AegiroCoreTests",
            dependencies: ["AegiroCore"]
        ),
    ]
)
