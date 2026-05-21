import Testing
@testable import StudioCore

struct ClusterTitleCacheTokenTests {
    @Test
    func tokenChangesWhenLayoutCountersMoveTogether() {
        let before = ClusterTitleCacheToken.make(
            layoutRevision: 3,
            sidecarRevision: 3,
            playbackKey: 0,
            isStoryOnlyMode: false,
            hasFocusPlan: false,
            showClusterHalos: true
        )
        let after = ClusterTitleCacheToken.make(
            layoutRevision: 4,
            sidecarRevision: 4,
            playbackKey: 0,
            isStoryOnlyMode: false,
            hasFocusPlan: false,
            showClusterHalos: true
        )

        #expect(before != after)
    }

    @Test
    func legacyXorTokenWouldStayConstantWhenCountersMoveTogether() {
        let before = 3 ^ 3 ^ 0
        let after = 4 ^ 4 ^ 0
        #expect(before == after)
    }
}
