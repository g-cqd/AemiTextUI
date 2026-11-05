/// A monotone, smooth map between two scroll coordinates that are anchored at the same places: the position of each block of a Markdown source in an editor, and the position of the same block in the page drawn from it.
///
/// Each side knows where its blocks are, and nothing else is the same between them: a source line is a fixed height and a rendered paragraph, table or diagram is not. The map passes through every anchor, so a block's top is where its page is, and between
/// two anchors it moves smoothly: a piecewise-linear map is continuous but its speed jumps at every anchor, which shows as a lurch when scrolling past a block boundary. This is a monotone cubic (Fritsch and Carlson, 1980): it passes through the anchors,
/// has a continuous slope everywhere, and never goes backwards or overshoots between two of them, so scrolling forward on one side never scrolls the other back.
///
/// It is made to be fed what a view reports and to be rebuilt whenever that changes: anchors that are not numbers, out of order, repeated, or that go backwards on the target side are repaired (not rejected), so a layout that is half measured gives a map
/// that is worse and not a crash. Lookups are a binary search and a polynomial: O(log anchors). Memory is a few numbers per anchor. Nothing here knows of AppKit or SwiftUI.
public struct ScrollMap: Sendable {
    /// One place the two sides agree on.
    public struct Anchor: Sendable, Equatable {
        public var source: Double
        public var target: Double

        public init(source: Double, target: Double) {
            self.source = source
            self.target = target
        }
    }

    /// The anchors as used: finite, strictly ascending in `source`, never descending in `target`.
    public let anchors: [Anchor]
    /// The slope of the map at each anchor.
    private let slopes: [Double]
    /// Whether the anchors given had to be repaired.
    public let wasRepaired: Bool

    /// A map through `anchors`. Fewer than one anchor is the identity; one is a shift; the ends continue at the slope they have there.
    public init(anchors given: [Anchor]) {
        var wasRepaired = false
        var clean = given.filter { $0.source.isFinite && $0.target.isFinite }
        if clean.count != given.count { wasRepaired = true }
        if !clean.isSorted(by: { $0.source < $1.source }) {
            clean.sort { $0.source < $1.source }
            wasRepaired = true
        }
        // Two anchors at one source position are one: the later, in the order given, is the one a view measured last.
        var unique: [Anchor] = []
        for anchor in clean {
            if let last = unique.last, last.source == anchor.source {
                unique[unique.count - 1] = anchor
                wasRepaired = true
            } else {
                unique.append(anchor)
            }
        }
        // The target never goes back: a block the page measured as ending above where the one before it ended is held level with it.
        for index in unique.indices.dropFirst() where unique[index].target < unique[index - 1].target {
            unique[index].target = unique[index - 1].target
            wasRepaired = true
        }
        anchors = unique
        slopes = Self.slopes(of: unique)
        self.wasRepaired = wasRepaired
    }

    /// The target position of `source`.
    /// - Complexity: O(log anchors).
    public func target(forSource source: Double) -> Double {
        guard source.isFinite else {
            return source.isNaN ? 0 : (source > 0 ? anchors.last?.target ?? source : anchors.first?.target ?? source)
        }
        guard let first = anchors.first, let last = anchors.last else { return source }
        if anchors.count == 1 { return first.target + (source - first.source) }
        if source <= first.source { return first.target + slopes[0] * (source - first.source) }
        if source >= last.source { return last.target + slopes[anchors.count - 1] * (source - last.source) }
        let index = segment(containing: source)
        return Self.hermite(anchors[index], anchors[index + 1], slopes[index], slopes[index + 1], at: source)
    }

    /// The source position of `target`: where a position on the page is in the source. A target that several sources map to (a rendered block with no height) gives the first of them.
    /// - Complexity: O(log anchors) and a bounded search within one segment.
    public func source(forTarget target: Double) -> Double {
        guard target.isFinite else {
            return target.isNaN ? 0 : (target > 0 ? anchors.last?.source ?? target : anchors.first?.source ?? target)
        }
        guard let first = anchors.first, let last = anchors.last else { return target }
        if anchors.count == 1 { return first.source + (target - first.target) }
        if target <= first.target { return first.source + (slopes[0] > 0 ? (target - first.target) / slopes[0] : 0) }
        if target >= last.target {
            let slope = slopes[anchors.count - 1]
            return last.source + (slope > 0 ? (target - last.target) / slope : 0)
        }
        // The first segment whose end reaches the target: the anchors' targets never descend, so this is a binary search.
        var low = 0
        var high = anchors.count - 1
        while low < high {
            let middle = (low + high) / 2
            if anchors[middle].target >= target { high = middle } else { low = middle + 1 }
        }
        let index = Swift.max(low - 1, 0)
        let left = anchors[index]
        let right = anchors[index + 1]
        if right.target == left.target { return left.source }
        // The cubic is monotone on a segment, so bisection finds the one source that maps to `target`.
        var lower = left.source
        var upper = right.source
        for _ in 0 ..< 60 {
            let middle = (lower + upper) / 2
            if Self.hermite(left, right, slopes[index], slopes[index + 1], at: middle) < target {
                lower = middle
            } else {
                upper = middle
            }
        }
        return (lower + upper) / 2
    }

    // MARK: Inside

    private func segment(containing source: Double) -> Int {
        var low = 0
        var high = anchors.count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if anchors[middle].source <= source { low = middle } else { high = middle }
        }
        return low
    }

    /// The cubic Hermite polynomial through two anchors with the given slopes.
    private static func hermite(
        _ left: Anchor,
        _ right: Anchor,
        _ leftSlope: Double,
        _ rightSlope: Double,
        at source: Double
    ) -> Double {
        let width = right.source - left.source
        let t = (source - left.source) / width
        let t2 = t * t
        let t3 = t2 * t
        let h00 = 2 * t3 - 3 * t2 + 1
        let h10 = t3 - 2 * t2 + t
        let h01 = -2 * t3 + 3 * t2
        let h11 = t3 - t2
        return h00 * left.target + h10 * width * leftSlope + h01 * right.target + h11 * width * rightSlope
    }

    /// Fritsch and Carlson's slopes: the mean of the two neighbouring secants, or zero where they disagree in sign or where either is zero, and then held to three times the smaller secant, which is what keeps a segment monotone.
    private static func slopes(of anchors: [Anchor]) -> [Double] {
        let count = anchors.count
        guard count >= 2 else { return [Double](repeating: 1, count: count) }
        var secants = [Double](repeating: 0, count: count - 1)
        for index in 0 ..< count - 1 {
            secants[index] =
                (anchors[index + 1].target - anchors[index].target)
                / (anchors[index + 1].source - anchors[index].source)
        }
        var slopes = [Double](repeating: 0, count: count)
        slopes[0] = secants[0]
        slopes[count - 1] = secants[count - 2]
        for index in 1 ..< count - 1 {
            let before = secants[index - 1]
            let after = secants[index]
            if before * after <= 0 {
                slopes[index] = 0
            } else {
                // The harmonic mean: never larger than three times either secant, and smooth where they are alike.
                slopes[index] = 2 * before * after / (before + after)
            }
        }
        // An end slope that points the wrong way, or is steeper than three times its secant, would overshoot.
        for (end, secant) in [(0, secants[0]), (count - 1, secants[count - 2])] {
            if slopes[end] * secant <= 0 {
                slopes[end] = 0
            } else if abs(slopes[end]) > 3 * abs(secant) {
                slopes[end] = 3 * secant
            }
        }
        return slopes
    }
}

extension Array {
    fileprivate func isSorted(by areInIncreasingOrder: (Element, Element) -> Bool) -> Bool {
        for index in indices.dropFirst() where areInIncreasingOrder(self[index], self[index - 1]) { return false }
        return true
    }
}
