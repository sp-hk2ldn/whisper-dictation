import Testing
@testable import WhisperDictationFeature

struct FallbackFieldSearchTests {
    @Test func findsNestedInput() {
        let result = FallbackFieldSearch.search(root: 0,
            children: { $0 < 3 ? [$0 + 1] : [] }, isCandidate: { $0 == 3 })
        #expect(result.uniqueCandidate == 3)
    }

    @Test func refusesAmbiguousInputs() {
        let result = FallbackFieldSearch.search(root: 0,
            children: { $0 == 0 ? [1, 2] : [] }, isCandidate: { $0 > 0 })
        #expect(result.uniqueCandidate == nil)
    }

    @Test func countsEveryAmbiguousInput() {
        let expected = FallbackFieldSearchResult.complete(candidates: [1, 2, 3])
        let result = FallbackFieldSearch.search(root: 0,
            children: { $0 == 0 ? [1, 2, 3] : [] }, isCandidate: { $0 > 0 })
        #expect(result == expected)
    }

    @Test func incompleteSearchCannotClaimUniqueInput() {
        let result = FallbackFieldSearch.search(root: 0, limit: 3,
            children: { [$0 + 1] }, isCandidate: { $0 == 1 })
        #expect(result.uniqueCandidate == nil)
    }
}
