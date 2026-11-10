// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CategoryRecommenderMail",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CategoryRecommender", targets: ["CategoryRecommender"])
    ],
    targets: [
        .target(name: "MailCore"),
        .executableTarget(name: "CategoryRecommender", dependencies: ["MailCore"]),
        .testTarget(name: "MailCoreTests", dependencies: ["MailCore"]),
    ],
    swiftLanguageModes: [.v5]
)
