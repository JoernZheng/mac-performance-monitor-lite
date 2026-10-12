// SPDX-License-Identifier: MIT
import XCTest

@testable import MacPerfMonitorCore

final class BoundedCacheTests: XCTestCase {
    func testEvictsLeastRecentlyUsedIncludingNegativeEntries() {
        var cache = BoundedCache<String, String?>(capacity: 2)
        cache.insert(nil, forKey: "unsigned")
        cache.insert("one", forKey: "one")
        XCTAssertNotNil(cache.value(forKey: "unsigned") as Any?)
        cache.insert("two", forKey: "two")
        XCTAssertEqual(cache.count, 2)
        XCTAssertNil(cache.value(forKey: "one"))
        XCTAssertNotNil(cache.value(forKey: "unsigned") as Any?)
        cache.removeAll()
        XCTAssertEqual(cache.count, 0)
    }

    func testChurnAndReplacementStayWithinCapacity() {
        var cache = BoundedCache<Int, Int>(capacity: 16)
        for index in 0..<10_000 {
            cache.insert(index, forKey: index)
            cache.insert(index + 1, forKey: index)
            XCTAssertLessThanOrEqual(cache.count, 16)
            XCTAssertEqual(cache.value(forKey: index), index + 1)
        }
    }

    func testSigningCachesBoundChurnAndRememberNil() {
        var teamReads = 0
        var orgReads = 0
        let resolver = CodeSigningResolver(
            resolveTeamID: { _ in
                teamReads += 1
                return nil
            },
            resolveOrganization: { _ in
                orgReads += 1
                return nil
            })
        for index in 0..<2048 {
            let path = "/temporary/\(index)"
            XCTAssertNil(resolver.teamID(forExecutablePath: path))
            XCTAssertNil(resolver.teamID(forExecutablePath: path))
            XCTAssertNil(resolver.organization(forExecutablePath: path))
            XCTAssertNil(resolver.organization(forExecutablePath: path))
        }
        XCTAssertEqual(teamReads, 2048)
        XCTAssertEqual(orgReads, 2048)
        _ = resolver.teamID(forExecutablePath: "/temporary/0")
        _ = resolver.organization(forExecutablePath: "/temporary/0")
        XCTAssertEqual(teamReads, 2049)
        XCTAssertEqual(orgReads, 2049)
        resolver.reset()
        _ = resolver.teamID(forExecutablePath: "/temporary/0")
        XCTAssertEqual(teamReads, 2050)
    }

    func testBundleCacheEvictsOldPaths() {
        var reads = 0
        var cache = BundleIDCache(readPlist: { _ in
            reads += 1
            return nil
        })
        for index in 0..<2048 {
            let path = "/Applications/\(index).app/Contents/MacOS/app"
            _ = cache.bundleID(fromExecutablePath: path)
            _ = cache.bundleID(fromExecutablePath: path)
        }
        XCTAssertEqual(reads, 2048)
        _ = cache.bundleID(fromExecutablePath: "/Applications/0.app/Contents/MacOS/app")
        XCTAssertEqual(reads, 2049)
    }
}
