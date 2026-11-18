import Testing

@testable import PutioHarnessKit

@Test(
  arguments: [
    (nil, 18, 1.0),
    (40.0, 0, 1.0),
    (0.0, 18, 1.0),
    (18.0, 18, 2.0),
    (36.0, 18, 3.0),
    (200.0, 18, 4.0),
  ] as [(Double?, Int, Double)])
func timeoutScaleGrowsWithLoadPerCoreUpToFourTimes(
  loadAverage: Double?, processors: Int, scale: Double
) {
  #expect(HostLoad.timeoutScale(loadAverage: loadAverage, processors: processors) == scale)
}
