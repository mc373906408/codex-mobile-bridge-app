"""Static Xcode/flavor isolation checks; these do not replace a macOS build."""

import json
from pathlib import Path
import plistlib
import xml.etree.ElementTree as ET

from ios_project import parse_project

ROOT = Path(__file__).resolve().parents[1]
SHARED = {
    "CloudPolicy.swift", "CloudMetadataStore.swift", "CloudKeyVault.swift",
    "CloudPreviewDecryptor.swift", "CloudPreviewService.swift",
}
APP_SOURCES = SHARED | {
    "CloudFence.swift", "CloudPushBridge.swift", "AppDelegate.swift", "SceneDelegate.swift", "GeneratedPluginRegistrant.m",
}
EXTENSION_SOURCES = SHARED | {"CloudCompletionGate.swift", "NotificationService.swift"}
CLOUD_CONFIGURATIONS = {f"{mode}-cloud" for mode in ("Debug", "Profile", "Release")}
LIBRARY = "$(BUILT_PRODUCTS_DIR)/bridge-preview/libbridge_preview.a"


def require(condition, message):
    if not condition:
        raise ValueError(message)


class Project:
    def __init__(self, root, data):
        self.root = root
        self.data = data
        self.objects = data["objects"]
        self.project = self.objects[data["rootObject"]]
        self.parents = {}
        for identity, item in self.objects.items():
            if item["isa"] in {"PBXGroup", "PBXVariantGroup"}:
                for child in item.get("children", []):
                    require(child not in self.parents, f"Multiple source groups for {child}")
                    self.parents[child] = identity

    def path(self, identity, seen=None):
        seen = set() if seen is None else seen
        require(identity not in seen, "Cyclic Xcode source groups")
        seen.add(identity)
        item = self.objects[identity]
        tree = item.get("sourceTree", "<group>")
        require(tree in {"<group>", "SOURCE_ROOT"}, f"Not a source reference: {identity}")
        parent = self.parents.get(identity)
        base = self.path(parent, seen) if tree == "<group>" and parent else self.root / "ios"
        return base / item.get("path", "")

    def target(self, name):
        candidates = [(identity, item) for identity, item in self.objects.items()
                      if item["isa"] == "PBXNativeTarget" and item["name"] == name]
        require(len(candidates) == 1, f"Expected one {name} target")
        identity, target = candidates[0]
        require(identity in self.project["targets"], f"Unreachable target: {name}")
        return identity, target

    def phases(self, target, kind=None):
        return [self.objects[identity] for identity in target["buildPhases"]
                if kind is None or self.objects[identity]["isa"] == kind]

    def files(self, phase):
        return [self.objects[identity]["fileRef"] for identity in phase.get("files", [])]

    def sources(self, target):
        references = [ref for phase in self.phases(target, "PBXSourcesBuildPhase") for ref in self.files(phase)]
        paths = [self.path(ref) for ref in references]
        require(all(path.is_file() for path in paths), f"Missing source in {target['name']}")
        require(len(set(paths)) == len(paths), f"Duplicate source in {target['name']}")
        return {path.name for path in paths}

    def configurations(self, target):
        configurations = self.objects[target["buildConfigurationList"]]["buildConfigurations"]
        result = {self.objects[identity]["name"]: self.objects[identity] for identity in configurations}
        require(len(result) == len(configurations), "Duplicate build configuration names")
        return result


def check_references(data):
    objects = data["objects"]
    require(data["rootObject"] in objects, "Missing root project")
    arrays = {"children", "buildPhases", "files", "dependencies", "targets", "buildConfigurations"}
    singles = {"buildConfigurationList", "baseConfigurationReference", "fileRef", "productReference",
               "mainGroup", "productRefGroup", "target", "targetProxy", "containerPortal"}
    for identity, item in objects.items():
        for field in arrays | singles:
            if field not in item:
                continue
            references = item[field] if field in arrays else [item[field]]
            require(all(reference in objects for reference in references), f"Dangling {field} in {identity}")


def check_project(root=ROOT, data=None):
    root = Path(root)
    if data is None:
        data = parse_project((root / "ios/Runner.xcodeproj/project.pbxproj").read_text(encoding="utf-8"))
    check_references(data)
    project = Project(root, data)
    _, ordinary = project.target("Runner")
    cloud_id, cloud = project.target("RunnerCloud")
    extension_id, extension = project.target("BridgeNotificationService")
    require(APP_SOURCES == project.sources(ordinary), "Ordinary Runner source membership changed")
    require(project.sources(cloud) == project.sources(ordinary), "Cloud app must use the same app sources")
    require(project.sources(extension) == EXTENSION_SOURCES,
            "Extension must be preview-only, without Flutter, account or control sources")
    require(not ordinary["dependencies"], "Ordinary Runner must not build the extension")
    dependencies = [project.objects[identity] for identity in cloud["dependencies"]]
    require(len(dependencies) == 1 and dependencies[0].get("target") == extension_id,
            "RunnerCloud must explicitly depend on BridgeNotificationService")
    require(not extension["dependencies"], "Extension must not depend on Flutter or the app")

    producers = [(identity, phase) for identity, phase in project.objects.items()
                 if phase["isa"] == "PBXShellScriptBuildPhase" and
                 ("build_ios_preview.py" in phase.get("shellScript", "") or LIBRARY in phase.get("outputPaths", []))]
    require(len(producers) == 1, "Preview static library must have exactly one producer")
    producer_id, producer = producers[0]
    require(producer_id in extension["buildPhases"] and producer["outputPaths"] == [LIBRARY],
            "Only the NSE may produce the preview static library")
    require("build_ios_preview.py" in producer["shellScript"], "Unexpected preview build script")
    require(extension["buildPhases"][0] == producer_id, "Build preview Rust before linking the extension")
    embeds = project.phases(cloud, "PBXCopyFilesBuildPhase")
    embeds = [phase for phase in embeds if extension["productReference"] in project.files(phase)]
    require(len(embeds) == 1 and embeds[0]["dstSubfolderSpec"] == "13", "Cloud app must embed exactly one NSE")
    phases = project.phases(cloud)
    thin = [phase for phase in phases if "embed_and_thin" in phase.get("shellScript", "")]
    require(len(thin) == 1 and phases.index(embeds[0]) < phases.index(thin[0]),
            "Embed the extension before Flutter Thin Binary to avoid a dependency cycle")
    require(not any(extension["productReference"] in project.files(phase) for phase in project.phases(ordinary)),
            "Ordinary Runner must not embed the extension")

    normal_configurations = project.configurations(ordinary)
    require(set(normal_configurations) == {"Debug", "Profile", "Release"}, "Default build configurations changed")
    for configuration in normal_configurations.values():
        settings = configuration["buildSettings"]
        require("BRIDGE_CLOUD_PUSH" not in json.dumps(settings) and "bridge_preview" not in json.dumps(settings),
                "Ordinary Runner must not enable or link preview crypto")
        require(settings["INFOPLIST_FILE"] == "Runner/Info.plist" and
                settings["CODE_SIGN_ENTITLEMENTS"] == "Runner/Runner.entitlements", "Default signing isolation changed")
    for target in (cloud, extension):
        configurations = project.configurations(target)
        require(set(configurations) == CLOUD_CONFIGURATIONS, f"Missing cloud configurations for {target['name']}")
        for name, configuration in configurations.items():
            settings = configuration["buildSettings"]
            require("BRIDGE_CLOUD_PUSH" in settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"], "Missing cloud Swift flag")
            require("-lbridge_preview" in settings["OTHER_LDFLAGS"] and
                    "$(BUILT_PRODUCTS_DIR)/bridge-preview" in settings["LIBRARY_SEARCH_PATHS"], "Missing preview linkage")
            require(settings["CURRENT_PROJECT_VERSION"] == "$(FLUTTER_BUILD_NUMBER)", "App/NSE versions must match")
            base = project.path(configuration["baseConfigurationReference"])
            if target is cloud:
                require(base == root / f"ios/Flutter/{name}.xcconfig", "Cloud app must use Flutter flavor xcconfigs")
                require(settings["PRODUCT_NAME"] == "Runner" and settings["PRODUCT_MODULE_NAME"] == "Runner",
                        "Flutter expects the cloud product and module to remain Runner")
                require(settings["INFOPLIST_FILE"] == "Runner/CloudInfo.plist" and
                        settings["CODE_SIGN_ENTITLEMENTS"] == "Runner/RunnerCloud.entitlements", "Cloud app signing mismatch")
            else:
                require(base == root / "ios/CloudShared/ExtensionCloud.xcconfig", "NSE must not inherit Pods linkage")
                require(settings["APPLICATION_EXTENSION_API_ONLY"] == "YES" and settings["SKIP_INSTALL"] == "YES",
                        "NSE must be extension-safe and embedded, not independently installed")
                require(settings["MARKETING_VERSION"] == "$(FLUTTER_BUILD_NAME)", "NSE marketing version mismatch")
    project_configurations = project.configurations(project.project)
    require(CLOUD_CONFIGURATIONS <= set(project_configurations), "Project is missing Flutter flavor configurations")
    check_runtime_files(root, cloud_id)
    return {"objects": len(project.objects), "shared_sources": len(SHARED), "preview_producers": len(producers)}


def check_runtime_files(root, cloud_id):
    ios = root / "ios"
    load = lambda path: plistlib.loads((ios / path).read_bytes())
    ordinary = load("Runner/Info.plist")
    cloud = load("Runner/CloudInfo.plist")
    extra = {"BridgeCloudAppGroup": "$(BRIDGE_CLOUD_APP_GROUP)",
             "BridgePreviewKeychainGroup": "$(BRIDGE_CLOUD_PREVIEW_KEYCHAIN_GROUP)"}
    require(cloud == ordinary | extra and not set(extra) & set(ordinary), "Cloud Info.plist must only add runtime groups")
    control_group = "$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)"
    preview_group = "$(BRIDGE_CLOUD_PREVIEW_KEYCHAIN_GROUP)"
    app = load("Runner/RunnerCloud.entitlements")
    extension = load("BridgeNotificationService/BridgeNotificationService.entitlements")
    require(app["keychain-access-groups"] == [control_group, preview_group], "Account/control Keychain group must remain first")
    require(extension["keychain-access-groups"] == [preview_group], "NSE must only access the preview Keychain group")
    require(app["com.apple.security.application-groups"] == extension["com.apple.security.application-groups"] ==
            ["$(BRIDGE_CLOUD_APP_GROUP)"], "App and NSE must share their dedicated App Group")
    normal_entitlements = load("Runner/Runner.entitlements")
    require(not {"aps-environment", "com.apple.security.application-groups"} & set(normal_entitlements) and
            normal_entitlements.get("keychain-access-groups") == [control_group],
            "Ordinary build must retain only its existing account/control entitlement")
    require("aps-environment" not in extension, "NSE must not register for APNs")
    scheme = ET.parse(ios / "Runner.xcodeproj/xcshareddata/xcschemes/cloud.xcscheme").getroot()
    for reference in scheme.iter("BuildableReference"):
        require(reference.get("BlueprintIdentifier") == cloud_id and reference.get("BlueprintName") == "RunnerCloud" and
                reference.get("BuildableName") == "Runner.app", "Cloud scheme selects the wrong target")
    require(len(scheme.findall("./BuildAction/BuildActionEntries/BuildActionEntry")) == 1, "Cloud scheme must select only the app")
    for action, configuration in {"LaunchAction": "Debug-cloud", "TestAction": "Debug-cloud",
                                  "ProfileAction": "Profile-cloud", "ArchiveAction": "Release-cloud"}.items():
        require(scheme.find(action).get("buildConfiguration") == configuration, f"Incorrect scheme {action}")
    for name in CLOUD_CONFIGURATIONS:
        text = (ios / f"Flutter/{name}.xcconfig").read_text(encoding="utf-8")
        require(f"Pods-RunnerCloud.{name.lower()}.xcconfig" in text and '"Generated.xcconfig"' in text and
                '"CloudCommon.xcconfig"' in text and '"../Cloud.local.xcconfig"' in text, "Incomplete cloud xcconfig")
    extension_config = (ios / "CloudShared/ExtensionCloud.xcconfig").read_text(encoding="utf-8")
    require("Pods" not in "\n".join(line for line in extension_config.splitlines() if not line.startswith("//")),
            "NSE xcconfig must not load Flutter pods")
    podfile = (ios / "Podfile").read_text(encoding="utf-8")
    require("target 'RunnerCloud'" in podfile and "target 'BridgeNotificationService'" not in podfile,
            "Pods must target the cloud app, never the NSE")
    for name in CLOUD_CONFIGURATIONS:
        require(f"'{name}' =>" in podfile, f"Podfile is missing {name}")


if __name__ == "__main__":
    print(json.dumps(check_project(), sort_keys=True))
    print("Static iOS cloud build contract passed; no Xcode compilation or device test ran.")
