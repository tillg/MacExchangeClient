// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MailReplica",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "MailModel"),
        .executableTarget(name: "MailReplica", dependencies: ["MailModel"]),
        .testTarget(name: "MailModelTests", dependencies: ["MailModel"]),
    ]
)
