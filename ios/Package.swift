// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "BridgeCloudPolicy",
  platforms: [.macOS(.v12)],
  products: [.library(name: "BridgeCloudPolicy", targets: ["BridgeCloudPolicy"])],
  targets: [
    .target(name: "BridgeCloudPolicy", path: "CloudShared",
      exclude: ["BridgePreview.h", "ExtensionCloud.xcconfig"],
      sources: ["CloudPolicy.swift", "CloudFence.swift", "CloudCompletionGate.swift",
                "CloudMetadataStore.swift", "CloudKeyVault.swift", "CloudPreviewDecryptor.swift",
                "CloudPreviewService.swift"]),
    .testTarget(name: "BridgeCloudPolicyTests", dependencies: ["BridgeCloudPolicy"], path: "CloudTests"),
  ])
