import Testing

@testable import WicketCore

@Test func aStreamingDetailNeverShrinksUntilItsRunEnds() {
    var measure = DetailMeasure(frame: 1, height: 40)
    measure.record(120, frame: 1, isLoading: true)
    measure.record(100, frame: 1, isLoading: true)
    #expect(measure.height(of: 1, isLoading: true) == 120)
    // The run ended: the card fits the final text, even without a new measurement.
    #expect(measure.height(of: 1, isLoading: false) == 100)
    measure.record(90, frame: 1, isLoading: false)
    #expect(measure.height(of: 1, isLoading: false) == 90)
    // A new run grows from what is there.
    measure.record(95, frame: 1, isLoading: true)
    #expect(measure.height(of: 1, isLoading: true) == 95)
}

@Test func aMeasurementBelongsToItsFrame() {
    var measure = DetailMeasure(frame: 1, height: 300)
    #expect(measure.height(of: 2, isLoading: false) == nil)
    measure.record(80, frame: 2, isLoading: true)
    #expect(measure.height(of: 2, isLoading: true) == 80)
    #expect(measure.height(of: 1, isLoading: false) == nil)
}
