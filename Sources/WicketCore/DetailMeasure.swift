/// The measured height of a detail frame's content, which sizes its card: markdown wraps, so a page
/// can't be sized from rows like a list. It holds the latest measurement and, while the frame's
/// command is still running, the tallest one, so a streaming answer's card grows with the text and
/// never shrinks mid-stream (a closing `**` or a code fence can briefly reflow it shorter); once the
/// run ends, the card fits what is there.
public struct DetailMeasure: Equatable, Sendable {
    public let frame: Frame.ID
    private var latest: Double
    private var peak: Double

    public init(frame: Frame.ID, height: Double) {
        self.frame = frame
        latest = height
        peak = height
    }

    /// Records a new measurement of `frame`, replacing one of another frame.
    public mutating func record(_ height: Double, frame: Frame.ID, isLoading: Bool) {
        guard frame == self.frame else {
            self = DetailMeasure(frame: frame, height: height)
            return
        }
        latest = height
        peak = isLoading ? max(peak, height) : height
    }

    /// The height to size `frame`'s card by; nil until it has been measured.
    public func height(of frame: Frame.ID, isLoading: Bool) -> Double? {
        guard frame == self.frame else { return nil }
        return isLoading ? peak : latest
    }
}
