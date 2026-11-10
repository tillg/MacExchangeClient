// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MailReplica",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "MailModel"),
        .target(name: "EWS", dependencies: ["MailModel"]),
        .executableTarget(name: "MailReplica", dependencies: ["MailModel", "EWS"]),
        .testTarget(name: "MailModelTests", dependencies: ["MailModel", "EWS"]),
    ]
)
