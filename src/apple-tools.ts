export const appleTools = [
  [
    "xcodebuild",
    "/usr/bin/xcodebuild",
    [],
    "Build, test, archive and export host apps and Messages extensions",
  ],
  [
    "swift",
    "/usr/bin/xcrun",
    ["swift"],
    "Swift packages and command-line tools",
  ],
  ["swiftc", "/usr/bin/xcrun", ["swiftc"], "Compile Swift sources"],
  [
    "simctl",
    "/usr/bin/xcrun",
    ["simctl"],
    "Create, boot, install, launch, capture and configure dedicated simulators",
  ],
  [
    "devicectl",
    "/usr/bin/xcrun",
    ["devicectl"],
    "Install, launch, inspect and manage explicitly selected developer devices",
  ],
  [
    "xcresulttool",
    "/usr/bin/xcrun",
    ["xcresulttool"],
    "Read test results and export UI screenshots/attachments",
  ],
  [
    "xctrace",
    "/usr/bin/xcrun",
    ["xctrace"],
    "Instruments profiling and trace export",
  ],
  [
    "metal",
    "/usr/bin/xcrun",
    ["metal"],
    "Compile Metal shaders for AR and visual extensions",
  ],
  ["metallib", "/usr/bin/xcrun", ["metallib"], "Link compiled Metal libraries"],
  [
    "realitytool",
    "/usr/bin/xcrun",
    ["realitytool"],
    "Reality asset tooling when installed with Xcode",
  ],
  ["actool", "/usr/bin/xcrun", ["actool"], "Compile asset catalogs"],
  [
    "ibtool",
    "/usr/bin/xcrun",
    ["ibtool"],
    "Compile and inspect interface files",
  ],
  ["plutil", "/usr/bin/plutil", [], "Validate and transform property lists"],
  [
    "sips",
    "/usr/bin/sips",
    [],
    "Inspect and convert images and sticker assets",
  ],
  [
    "codesign",
    "/usr/bin/codesign",
    [],
    "Inspect/sign developer-built artifacts with local identities",
  ],
] as const;
export function appleToolCommand(
  tool: string,
  args: string[],
  cwd?: string,
  timeoutSeconds = 120,
) {
  const entry = appleTools.find((t) => t[0] === tool);
  if (!entry)
    throw new Error("Unknown Apple tool; inspect apple.tools.catalog");
  return {
    executable: entry[1],
    arguments: [...entry[2], ...args],
    cwd,
    timeoutSeconds,
  };
}
export const developerFrameworks = [
  {
    name: "Messages",
    purpose: "MSConversation, MSMessage, live/template layouts, stickers",
    url: "https://developer.apple.com/documentation/messages",
  },
  {
    name: "ARKit",
    purpose: "Device tracking and scene understanding",
    url: "https://developer.apple.com/documentation/arkit",
  },
  {
    name: "RealityKit",
    purpose: "AR scenes and interactive 3D assets",
    url: "https://developer.apple.com/documentation/realitykit",
  },
  {
    name: "RoomPlan",
    purpose: "LiDAR room capture",
    url: "https://developer.apple.com/documentation/roomplan",
  },
  {
    name: "App Intents",
    purpose: "Expose app actions to Shortcuts and system experiences",
    url: "https://developer.apple.com/documentation/appintents",
  },
  {
    name: "Image Playground",
    purpose: "System image-generation UI where supported",
    url: "https://developer.apple.com/documentation/imageplayground",
  },
  {
    name: "PhotosUI / AVFoundation",
    purpose: "Media selection, recording and processing",
    url: "https://developer.apple.com/documentation/avfoundation",
  },
  {
    name: "Core Location / MapKit",
    purpose: "Permission-bound location and maps",
    url: "https://developer.apple.com/documentation/mapkit",
  },
  {
    name: "Vision / Core ML",
    purpose: "On-device image analysis and models",
    url: "https://developer.apple.com/documentation/vision",
  },
  {
    name: "Metal / SpriteKit / SceneKit",
    purpose: "Custom graphics and interactive game content",
    url: "https://developer.apple.com/documentation/metal",
  },
];
