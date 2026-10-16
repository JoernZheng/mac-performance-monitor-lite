import XCTest

@testable import RecorderKit

final class ConfigurationTests: XCTestCase {
    func testDefaultsValidate() throws { try RecorderConfiguration().validate() }
}
