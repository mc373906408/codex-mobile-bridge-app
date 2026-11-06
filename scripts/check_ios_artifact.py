"""Check built iOS bundle isolation; this is not a signing or device-delivery check."""

import argparse
import json
import mmap
from pathlib import Path
import plistlib


def check_network_symbols(app):
    # These configuration APIs are public on macOS but SPI on iOS. Check the
    # shipped binaries, including Rust frameworks, rather than just our sources.
    bundles = [app, *app.rglob('*.framework'), *app.rglob('*.appex')]
    for bundle in bundles:
        metadata = bundle / 'Info.plist'
        if not metadata.is_file():
            continue
        with metadata.open('rb') as stream:
            name = plistlib.load(stream).get('CFBundleExecutable', '')
        if not name or Path(name).name != name:
            raise ValueError('Invalid embedded executable name')
        binary = bundle / name
        if not binary.is_file() or not binary.stat().st_size:
            continue
        with binary.open('rb') as stream, mmap.mmap(stream.fileno(), 0, access=mmap.ACCESS_READ) as data:
            if data.find(b'_SCNetworkInterface') != -1:
                raise ValueError('iOS executable references private network interface APIs')


def info(bundle, package):
    with (bundle / "Info.plist").open("rb") as stream:
        value = plistlib.load(stream)
    if value.get("CFBundlePackageType") != package:
        raise ValueError("Unexpected iOS bundle package type")
    for key in ("CFBundleIdentifier", "CFBundleExecutable", "CFBundleVersion", "CFBundleShortVersionString"):
        if not isinstance(value.get(key), str) or not value[key] or "$" in value[key]:
            raise ValueError("Built iOS bundle contains an unresolved or missing identifier/version")
    name = value["CFBundleExecutable"]
    if Path(name).name != name or not (bundle / name).is_file():
        raise ValueError("Built iOS bundle executable is missing or invalid")
    return value


def check_app(path, cloud=False):
    app = Path(path).resolve()
    main = info(app, "APPL")
    extensions = sorted((app / "PlugIns").glob("*.appex"))
    groups = ("BridgeCloudAppGroup", "BridgePreviewKeychainGroup")
    if not cloud:
        if extensions or any(key in main for key in groups):
            raise ValueError("Ordinary iOS artifact must not embed the cloud extension or preview configuration")
    else:
        if len(extensions) != 1 or extensions[0].name != "BridgeNotificationService.appex":
            raise ValueError("Cloud iOS artifact must embed exactly its preview-only notification extension")
        extension = info(extensions[0], "XPC!")
        if not extension["CFBundleIdentifier"].startswith(main["CFBundleIdentifier"] + "."):
            raise ValueError("Cloud extension must belong to the app's bundle identifier")
        for key in ("CFBundleVersion", "CFBundleShortVersionString"):
            if extension[key] != main[key]:
                raise ValueError("Cloud app and extension versions must match")
        for key in groups:
            value = main.get(key)
            if not isinstance(value, str) or not value or "$" in value or extension.get(key) != value:
                raise ValueError("Cloud app and extension must share resolved preview groups")
        if not main["BridgeCloudAppGroup"].startswith("group.") or not main["BridgePreviewKeychainGroup"].endswith(".preview"):
            raise ValueError("Cloud preview storage groups are invalid")
        if extension.get("NSExtension", {}).get("NSExtensionPointIdentifier") != "com.apple.usernotifications.service":
            raise ValueError("Cloud extension must be a notification service extension")
        if (extensions[0] / "Frameworks/Flutter.framework").exists() or (extensions[0] / "Frameworks/App.framework").exists():
            raise ValueError("Cloud preview extension must not embed a Flutter engine")
    check_network_symbols(app)
    return {"bundle_id": main["CFBundleIdentifier"], "cloud": cloud, "extensions": len(extensions)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cloud", action="store_true")
    parser.add_argument("app", type=Path)
    args = parser.parse_args()
    print(json.dumps(check_app(args.app, args.cloud), sort_keys=True))
    print("iOS artifact structure passed; signing, Keychain access and device delivery are not verified.")


if __name__ == "__main__":
    main()
