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
    // Pure logic shared by both workers. No Beeper dependency, never touches Messages on import,
    // so every rule here is unit-testable against fixtures.
    .target(name: "MessagePilotKit", linkerSettings: [.linkedLibrary("sqlite3")]),
    .testTarget(name: "MessagePilotScopedTests", dependencies: ["MessagePilotScoped"]),
    .testTarget(
      name: "MessagePilotKitTests", dependencies: ["MessagePilotKit"],
      resources: [.copy("Fixtures")]),
    .executableTarget(
      name: "MessagePilotScoped", dependencies: ["MessagePilotKit"],
      linkerSettings: [.linkedLibrary("sqlite3")]),
    .executableTarget(
      name: "MessagePilotNative",
      dependencies: [
        "MessagePilotKit",
        .product(name: "IMessage", package: "platform-imessage"),
        .product(name: "PlatformSDK", package: "platform-imessage"),
      ]),
  ])
