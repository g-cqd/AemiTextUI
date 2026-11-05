import Testing

@testable import AemiTextScroll

@Suite("The scroll map")
struct ScrollMapTests {
    private typealias Anchor = ScrollMap.Anchor

    /// A seeded generator, so a failing case can be run again.
    private struct Generator {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }
    }

    /// Anchors the way two panes make them: source positions rise by whole lines, page positions by blocks of every height, some of them none at all.
    private func anchors(_ count: Int, seed: UInt64, flat: Bool = false) -> [Anchor] {
        var random = Generator(state: seed)
        var source = 0.0
        var target = 0.0
        var result: [Anchor] = []
        for _ in 0 ..< count {
            result.append(Anchor(source: source, target: target))
            source += (1 + (random.next() * 40).rounded(.down)) * 16
            target += flat && random.next() < 0.2 ? 0 : random.next() * 600
        }
        return result
    }

    @Test func `it passes through every anchor`() {
        let map = ScrollMap(anchors: anchors(50, seed: 1))
        for anchor in map.anchors { #expect(abs(map.target(forSource: anchor.source) - anchor.target) < 1e-9) }
        #expect(!map.wasRepaired)
    }

    @Test(arguments: [1, 2, 3, 4, 5, 6])
    func `it never goes backwards`(seed: UInt64) {
        let map = ScrollMap(anchors: anchors(80, seed: seed, flat: seed % 2 == 0))
        let end = map.anchors.last?.source ?? 0
        var last = -Double.infinity
        var x = -200.0
        while x <= end + 200 {
            let value = map.target(forSource: x)
            #expect(value >= last - 1e-9, "at \(x)")
            last = value
            x += 7.3
        }
    }

    @Test(arguments: [11, 12, 13, 14])
    func `between two anchors it stays between them`(seed: UInt64) {
        let map = ScrollMap(anchors: anchors(60, seed: seed, flat: true))
        for index in 0 ..< map.anchors.count - 1 {
            let left = map.anchors[index]
            let right = map.anchors[index + 1]
            for step in 0 ... 20 {
                let x = left.source + (right.source - left.source) * Double(step) / 20
                let value = map.target(forSource: x)
                #expect(value >= left.target - 1e-9 && value <= right.target + 1e-9, "no overshoot at \(x)")
            }
        }
    }

    @Test func `the slope is continuous at an anchor, which a piecewise-linear map's is not`() {
        let map = ScrollMap(anchors: [
            Anchor(source: 0, target: 0), Anchor(source: 100, target: 300), Anchor(source: 200, target: 400),
            Anchor(source: 300, target: 900)
        ])
        let h = 1e-4
        for anchor in map.anchors.dropFirst().dropLast() {
            let before = (map.target(forSource: anchor.source) - map.target(forSource: anchor.source - h)) / h
            let after = (map.target(forSource: anchor.source + h) - map.target(forSource: anchor.source)) / h
            #expect(abs(before - after) < 1e-2, "slope \(before) then \(after) at \(anchor.source)")
        }
    }

    @Test func `the inverse undoes the map where the page moves`() {
        let map = ScrollMap(anchors: anchors(40, seed: 21))
        var x = 1.0
        while x < (map.anchors.last?.source ?? 0) {
            let target = map.target(forSource: x)
            #expect(abs(map.source(forTarget: target) - x) < 1e-6, "at \(x)")
            x += 13.7
        }
    }

    @Test func `a block with no height on the page is one target, and the inverse gives where it starts`() {
        let map = ScrollMap(anchors: [
            Anchor(source: 0, target: 0), Anchor(source: 100, target: 50), Anchor(source: 200, target: 50),
            Anchor(source: 300, target: 120)
        ])
        #expect(map.target(forSource: 100) == 50 && map.target(forSource: 200) == 50)
        #expect(abs(map.source(forTarget: 50) - 100) < 1e-6)
    }

    @Test func `anchors that are wrong are repaired and the map is still monotone`() {
        let given = [
            Anchor(source: 100, target: 40), Anchor(source: .nan, target: 5), Anchor(source: 0, target: 0),
            Anchor(source: 100, target: 60), Anchor(source: 200, target: 30),
            Anchor(source: 300, target: .infinity), Anchor(source: 400, target: 90)
        ]
        let map = ScrollMap(anchors: given)
        #expect(map.wasRepaired)
        #expect(map.anchors.map(\.source) == [0, 100, 200, 400])
        #expect(
            map.anchors.map(\.target) == [0, 60, 60, 90],
            "the later of two at one source; a target that goes back held level"
        )
        var last = -Double.infinity
        for x in stride(from: -50.0, through: 500, by: 3) {
            let value = map.target(forSource: x)
            #expect(value >= last - 1e-9)
            last = value
        }
    }

    @Test func `with fewer than two anchors it is the identity, or a shift`() {
        #expect(ScrollMap(anchors: []).target(forSource: 42) == 42)
        #expect(ScrollMap(anchors: []).source(forTarget: 42) == 42)
        let one = ScrollMap(anchors: [Anchor(source: 10, target: 100)])
        #expect(one.target(forSource: 15) == 105)
        #expect(one.source(forTarget: 105) == 15)
    }

    @Test func `past the ends it goes on at the slope it has there`() {
        let map = ScrollMap(anchors: [
            Anchor(source: 0, target: 0), Anchor(source: 100, target: 200), Anchor(source: 200, target: 400)
        ])
        #expect(abs(map.target(forSource: 300) - 600) < 1e-9)
        #expect(abs(map.target(forSource: -50) + 100) < 1e-9)
        #expect(abs(map.source(forTarget: 600) - 300) < 1e-9)
    }

    @Test func `numbers that are not numbers do not trap`() {
        let map = ScrollMap(anchors: anchors(5, seed: 9))
        for value in [
            Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude,
            .leastNonzeroMagnitude
        ] {
            _ = map.target(forSource: value)
            _ = map.source(forTarget: value)
        }
        _ = ScrollMap(anchors: [Anchor(source: .nan, target: .nan), Anchor(source: .infinity, target: 1)])
            .target(forSource: 3)
    }

    @Test func `a hundred thousand anchors are searched in time that does not grow with them`() {
        let map = ScrollMap(anchors: anchors(100_000, seed: 77))
        let clock = ContinuousClock()
        let end = map.anchors.last?.source ?? 1
        let elapsed = clock.measure {
            var total = 0.0
            for step in 0 ..< 200_000 { total += map.target(forSource: end * Double(step) / 200_000) }
            #expect(total > 0)
        }
        #expect(elapsed < .seconds(2), "\(elapsed)")
    }
}
