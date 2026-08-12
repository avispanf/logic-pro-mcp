import Foundation
import Testing
@testable import LogicProMCP

@Suite("Issue289StaleRefresh")
struct Issue289StaleRefreshTests {
    @Test func currentObservedVersionAppliesWrite() async {
        let cache = StateCache()
        let observed = await cache.currentVersion(for: .transport)

        let applied = await cache.updateTransport(
            transport(tempo: 123),
            ifCurrent: observed
        )

        #expect(applied)
        #expect((await cache.getTransport()).tempo == 123)
        #expect(await cache.droppedStaleWriteCount(for: .transport) == 0)
    }

    @Test func staleSectionRevisionDropsWriteAndPreservesNewerValue() async {
        let cache = StateCache()
        let observed = await cache.currentVersion(for: .transport)
        await cache.updateTransport(transport(tempo: 130))

        let applied = await cache.updateTransport(
            transport(tempo: 90),
            ifCurrent: observed
        )

        #expect(!applied)
        #expect((await cache.getTransport()).tempo == 130)
        #expect(await cache.droppedStaleWriteCount(for: .transport) == 1)
    }

    @Test func staleProjectEpochDropsWriteWhenSectionRevisionStillMatches() async {
        let cache = StateCache()
        let observed = await cache.currentVersion(for: .transport)
        await cache.advanceProjectEpoch()
        let current = await cache.currentVersion(for: .transport)

        #expect(current.sectionRevision == observed.sectionRevision)
        #expect(current.projectEpoch > observed.projectEpoch)

        let applied = await cache.updateTransport(
            transport(tempo: 90),
            ifCurrent: observed
        )

        #expect(!applied)
        #expect((await cache.getTransport()).tempo == 120)
        #expect(await cache.droppedStaleWriteCount(for: .transport) == 1)
    }

    @Test func concurrentWritesFromSameObservationAllowOnlyOne() async {
        let cache = StateCache()
        let observed = await cache.currentVersion(for: .transport)

        async let first = cache.updateTransport(transport(tempo: 101), ifCurrent: observed)
        async let second = cache.updateTransport(transport(tempo: 202), ifCurrent: observed)
        let results = await [first, second]
        let surviving = await cache.getTransport()

        #expect(results.filter { $0 }.count == 1)
        #expect(results.filter { !$0 }.count == 1)
        #expect(surviving.tempo == 101 || surviving.tempo == 202)
        #expect(await cache.sectionRevision(.transport) == 1)
        #expect(await cache.droppedStaleWriteCount(for: .transport) == 1)
    }

    @Test func axTrackIdentitySnapshotMergesNewerMCUState() async {
        let cache = StateCache()
        let observed = await cache.currentVersion(for: .tracks)

        // Model one fresh MCU bank arriving while AX is walking the full
        // project. These writes create eight placeholder identities and move
        // the section revision beyond the poller's observation.
        await cache.updateTrack(at: 7) { $0.isMuted = true }
        await cache.selectOnly(trackAt: 4)

        let axTracks = (0..<52).map {
            TrackState(id: $0, name: "Real Track \($0 + 1)", type: .audio)
        }
        let applied = await cache.updateTracksFromAX(
            axTracks,
            ifProjectCurrent: observed
        )
        let merged = await cache.getTracks()

        #expect(applied)
        #expect(merged.count == 52)
        #expect(merged[0].name == "Real Track 1")
        #expect(merged[51].name == "Real Track 52")
        #expect(merged[7].isMuted)
        #expect(merged[4].isSelected)
        #expect(merged.filter(\.isSelected).count == 1)
        #expect(await cache.droppedStaleWriteCount(for: .tracks) == 0)
    }

    @Test func axTrackIdentitySnapshotRejectsPreviousProjectEpoch() async {
        let cache = StateCache()
        let observed = await cache.currentVersion(for: .tracks)
        await cache.advanceProjectEpoch()

        let applied = await cache.updateTracksFromAX(
            [TrackState(id: 0, name: "Old Project", type: .audio)],
            ifProjectCurrent: observed
        )

        #expect(!applied)
        #expect((await cache.getTracks()).isEmpty)
        #expect(await cache.droppedStaleWriteCount(for: .tracks) == 1)
    }

    private func transport(tempo: Double) -> TransportState {
        var state = TransportState()
        state.tempo = tempo
        state.lastUpdated = Date()
        return state
    }
}
