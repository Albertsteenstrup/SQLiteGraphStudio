import Testing
@testable import StudioCore

struct FixtureIsolationTests {
    @Test func repeatedFixtureNamesDoNotShareAFile() {
        #expect(TestSupport.temporaryDatabaseURL(named: "same") != TestSupport.temporaryDatabaseURL(named: "same"))
    }
}
