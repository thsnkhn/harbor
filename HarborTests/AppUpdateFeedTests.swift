import Foundation
import XCTest
@testable import Harbor

final class AppUpdateFeedTests: XCTestCase {
    func testBothProcessorFeedsStayOnTheExistingUpdateHost() throws {
        let legacy = try XCTUnwrap(URL(string: "https://thsnkhn.github.io/harbor/appcast.xml"))
        XCTAssertEqual(AppUpdateArchitecture.appleSilicon.feedURL(relativeTo: legacy).absoluteString,
                       "https://thsnkhn.github.io/harbor/appcast-arm64.xml")
        XCTAssertEqual(AppUpdateArchitecture.intel.feedURL(relativeTo: legacy).absoluteString,
                       "https://thsnkhn.github.io/harbor/appcast-x86_64.xml")
    }
}
