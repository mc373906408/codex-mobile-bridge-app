import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var cloudPush: CloudPushBridge?
  private var workspaceFiles: WorkspaceFileExport?
  private var accessibilityChannel: FlutterMethodChannel?
  private var transparencyObserver: NSObjectProtocol?
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    do {
      var support = try FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask,
        appropriateFor: nil, create: true)
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try support.setResourceValues(values)
      try FileManager.default.setAttributes(
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
        ofItemAtPath: support.path)
    } catch {
      // Do not silently start persistent storage without its backup/protection policy.
      return false
    }
    cloudPush = CloudPushBridge()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    cloudPush?.bind(engineBridge.applicationRegistrar.messenger())
    workspaceFiles = WorkspaceFileExport(engineBridge.applicationRegistrar.messenger())
    engineBridge.applicationRegistrar.register(
      BridgeGlassViewFactory(), withId: "dev.waken.bridge_mobile/liquid_glass")
    let channel = FlutterMethodChannel(
      name: "dev.waken.bridge_mobile/accessibility",
      binaryMessenger: engineBridge.applicationRegistrar.messenger())
    accessibilityChannel = channel
    channel.setMethodCallHandler { call, result in
      if call.method == "reduceTransparency" {
        result(UIAccessibility.isReduceTransparencyEnabled)
      } else if call.method == "supportsLiquidGlass" {
        result(BridgeGlassViewFactory.supported)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
    if let observer = transparencyObserver {
      NotificationCenter.default.removeObserver(observer)
    }
    transparencyObserver = NotificationCenter.default.addObserver(
      forName: UIAccessibility.reduceTransparencyStatusDidChangeNotification,
      object: nil, queue: .main
    ) { [weak self] _ in
      self?.accessibilityChannel?.invokeMethod("changed", arguments: nil)
    }
  }

  deinit {
    if let observer = transparencyObserver {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  override func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    cloudPush?.registered(deviceToken)
    super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
  }

  override func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
    cloudPush?.failedRegistration()
    super.application(application, didFailToRegisterForRemoteNotificationsWithError: error)
  }
}

private final class WorkspaceFileExport: NSObject, UIDocumentPickerDelegate {
  private let channel: FlutterMethodChannel
  private var pending: FlutterResult?

  init(_ messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "dev.waken.bridge_mobile/files", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "save" else { result(FlutterMethodNotImplemented); return }
      guard let self else { result(false); return }
      guard self.pending == nil else { result(FlutterError(code: "busy", message: "A save dialog is already open", details: nil)); return }
      guard let args = call.arguments as? [String: Any], let path = args["path"] as? String else {
        result(FlutterError(code: "invalid_file", message: "Missing download", details: nil)); return
      }
      let file = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
      guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
            file.path.hasPrefix(support.appendingPathComponent("downloads").resolvingSymlinksInPath().path + "/"),
            file.deletingLastPathComponent().lastPathComponent == "ready",
            file.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
            (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
        result(FlutterError(code: "invalid_file", message: "Only completed workspace downloads can be exported", details: nil)); return
      }
      let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      guard var presenter = scenes.flatMap({ $0.windows }).first(where: { $0.isKeyWindow })?.rootViewController else {
        result(FlutterError(code: "unavailable", message: "No active window", details: nil)); return
      }
      while let presented = presenter.presentedViewController { presenter = presented }
      let picker = UIDocumentPickerViewController(forExporting: [file], asCopy: true)
      picker.delegate = self
      self.pending = result
      presenter.present(picker, animated: true)
    }
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    let result = pending; pending = nil; result?(!urls.isEmpty)
  }
  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    let result = pending; pending = nil; result?(false)
  }
}
