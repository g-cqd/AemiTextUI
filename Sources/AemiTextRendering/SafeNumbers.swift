/// Conversions that cannot trap. A renderer is given sizes and offsets by code that has bugs and by documents that are hostile; `Int(Double.nan)`, `Int32(someInt)` and `a + b` all end the process on the wrong input, and none of that is the renderer's to decide.
/// A number that makes no sense is replaced by the nearest one that does, so the worst a bad input can do is draw something odd.
extension Int {
    /// The integer nearest `value`, saturating at the ends of `Int`; NaN is 0.
    init(clampingFinite value: Double) {
        if value.isNaN {
            self = 0
        } else if value >= 9.2e18 {
            self = .max
        } else if value <= -9.2e18 {
            self = .min
        } else {
            self = Int(value)
        }
    }

    /// `self + other`, saturating instead of overflowing.
    func saturatingAdding(_ other: Int) -> Int {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? (other > 0 ? .max : .min) : sum
    }
}

extension Double {
    /// `self` if it is finite, else `fallback`.
    func finite(or fallback: Double) -> Double { isFinite ? self : fallback }

    /// `self` held to `range`; NaN and infinities become `fallback` first.
    func clamped(to range: ClosedRange<Double>, fallback: Double) -> Double {
        Swift.min(Swift.max(finite(or: fallback), range.lowerBound), range.upperBound)
    }
}
