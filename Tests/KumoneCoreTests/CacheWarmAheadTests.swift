#if os(macOS)
import Foundation
import Testing
@testable import KumoneCore

private func warmTrack(_ id: Int) throws -> Track {
    try JSONDecoder().decode(Track.self, from: JSONSerialization.data(withJSONObject: ["id": id, "name": "Track \(id)", "dt": 180_000]))
}

@Suite @MainActor struct CacheWarmAheadTests {
    private func ids(_ queue: [Int], at index: Int, next: [Int] = [], repeatAll: Bool = false,
                     limit: Int = PlayerService.cacheWarmAheadCount) throws -> [Int] {
        let tracks = try queue.map(warmTrack)
        return PlayerService.warmCandidates(queue: tracks, currentIndex: index, playNext: try next.map(warmTrack),
                                            repeatAll: repeatAll, currentID: index >= 0 && index < queue.count ? queue[index] : nil,
                                            limit: limit).map(\.id)
    }

    @Test func takesTheNextTwoInOrder() throws {
        #expect(try ids([1, 2, 3, 4], at: 0) == [2, 3])
        #expect(try ids([1, 2, 3, 4], at: 2) == [4])
        #expect(try ids([1, 2, 3, 4], at: 3) == [])
    }

    @Test func playNextComesFirst() throws {
        #expect(try ids([1, 2, 3], at: 0, next: [9]) == [9, 2])
        #expect(try ids([1, 2, 3], at: 0, next: [9, 8, 7]) == [9, 8])
    }

    @Test func repeatAllWrapsWithoutTheCurrentTrack() throws {
        #expect(try ids([1, 2, 3], at: 2, repeatAll: true) == [1, 2])
        #expect(try ids([1, 2], at: 1, repeatAll: true) == [1])
        #expect(try ids([1], at: 0, repeatAll: true) == [])
    }

    @Test func noQueueMeansOnlyPlayNext() throws {
        #expect(try ids([], at: -1, next: [5]) == [5])
        #expect(try ids([1, 2], at: -1) == [])
    }
}
#endif
