// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "MessagePilotNative", platforms: [.macOS(.v14)],
  products: [
    .executable(name: "messagepilot-scoped", targets: ["MessagePilotScoped"]),
    .executable(name: "messagepilot-native", targets: ["MessagePilotNative"]),
  ],
  dependencies: [
    .package(
      url: "https://github.com/beeper/platform-imessage.git",
      revision: "fdc5640bfcf936c3d8208bc15411944b7ed9819c")
  ],
  targets: [
    .executableTarget(name: "MessagePilotScoped", linkerSettings: [.linkedLibrary("sqlite3")]),
    .executableTarget(
      name: "MessagePilotNative",
      dependencies: [
        .product(name: "IMessage", package: "platform-imessage"),
        .product(name: "PlatformSDK", package: "platform-imessage"),
      ]),
  ])
