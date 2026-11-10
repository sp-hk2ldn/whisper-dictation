import Foundation

enum FallbackFieldSearchResult<Node> {
    case complete(candidates: [Node])
    case incomplete(candidatesFound: Int)

    var uniqueCandidate: Node? {
        guard case .complete(let candidates) = self, candidates.count == 1 else { return nil }
        return candidates.first
    }
}

extension FallbackFieldSearchResult: Equatable where Node: Equatable {}

/// Fail closed if a bounded traversal cannot establish a unique candidate.
enum FallbackFieldSearch {
    static func search<Node>(root: Node, limit: Int = 250,
                             children: (Node) -> [Node],
                             isCandidate: (Node) -> Bool) -> FallbackFieldSearchResult<Node> {
        var queue = [root]
        var cursor = 0
        var candidates: [Node] = []
        while cursor < queue.count {
            guard cursor < limit else { return .incomplete(candidatesFound: candidates.count) }
            let node = queue[cursor]
            cursor += 1
            if isCandidate(node) {
                candidates.append(node)
            }
            let descendants = children(node)
            guard queue.count + descendants.count <= limit else {
                return .incomplete(candidatesFound: candidates.count)
            }
            queue.append(contentsOf: descendants)
        }
        return .complete(candidates: candidates)
    }
}
