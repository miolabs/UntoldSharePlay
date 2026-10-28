import UntoldSharePlay
import XCTest

final class SharePlayPluginContractTests: XCTestCase {
    func testIdentifiersAreNamespaced() {
        XCTAssertTrue(SharePlayPluginContract.pluginID.hasPrefix("com.untoldengine."))
        XCTAssertFalse(SharePlayPluginContract.version.isEmpty)
    }
}
