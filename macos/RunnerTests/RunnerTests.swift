import Cocoa
import FlutterMacOS
import XCTest

class RunnerTests: XCTestCase {

  func testApplicationBundleKeepsDownloadHelper() {
    let app = Bundle.main
    XCTAssertEqual(app.bundleIdentifier, "com.asterlink.app")
    let helper = app.bundleURL.appendingPathComponent("Contents/MacOS/asterlink_gopeed")
    XCTAssertTrue(FileManager.default.isExecutableFile(atPath: helper.path))
  }

}
