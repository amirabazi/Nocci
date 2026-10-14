// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Nocci",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Nocci", targets: ["Nocci"])],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.20.0")
    ],
    targets: [
        .executableTarget(
            name: "Nocci",
            dependencies: [.product(name: "Sparkle", package: "Sparkle"),
                           .product(name: "SwiftTerm", package: "SwiftTerm")],
            path: "Sources",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("Charts"),
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ])
    ])
