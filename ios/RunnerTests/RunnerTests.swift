import Flutter
import UIKit
import XCTest
@testable import Runner

class RunnerTests: XCTestCase {

  @MainActor
  func testGlassIsDecorationAndDoesNotReduceSystemEffectAlpha() {
    let glass = BridgeGlassView(frame: CGRect(x: 0, y: 0, width: 320, height: 60), arguments: ["radius": 28, "dark": true])
    let view = glass.effectView
    XCTAssertEqual(view.alpha, 1)
    XCTAssertEqual(view.layer.cornerRadius, 28)
    XCTAssertEqual(view.overrideUserInterfaceStyle, .dark)
    XCTAssertFalse(view.isUserInteractionEnabled)
    XCTAssertTrue(view.accessibilityElementsHidden)
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      XCTAssertTrue(BridgeGlassViewFactory.supported)
      XCTAssertTrue(view.effect is UIGlassEffect)
    } else {
      XCTAssertFalse(BridgeGlassViewFactory.supported)
      XCTAssertTrue(view.effect is UIBlurEffect)
    }
    #else
    XCTAssertFalse(BridgeGlassViewFactory.supported)
    XCTAssertTrue(view.effect is UIBlurEffect)
    #endif
  }

}
