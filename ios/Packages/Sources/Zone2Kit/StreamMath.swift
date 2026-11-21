import Foundation

/// Numbers derived on the phone from an activity's cached curves (resampled into equal buckets).
public enum StreamMath {
    public struct BestPower: Sendable, Equatable {
        public let seconds: Int
        public let watts: Double
    }

    /// Durations of the power curve (Strava's power curve, HealthFit's mean-maximal power).
    public static let powerDurations = [60, 120, 300, 600, 1200, 1800, 3600]

    /// Best average power over each duration that fits the recording; a bucket without power
    /// counts as 0 W (coasting). Buckets are ~10–20 s, so durations under a minute are not offered.
    public static func bestPower(_ streams: ActivityStreams, channel: String) -> [BestPower] {
        guard let raw = streams.series(channel), streams.bucketSec > 0 else { return [] }
        let xs = raw.map { $0 ?? 0 }
        var prefix = [0.0]
        prefix.reserveCapacity(xs.count + 1)
        for x in xs { prefix.append(prefix.last! + x) }
        return powerDurations.compactMap { d in
            let k = max(Int((Double(d) / streams.bucketSec).rounded()), 1)
            guard k <= xs.count else { return nil }
            var best = 0.0
            for i in 0...(xs.count - k) { best = max(best, prefix[i + k] - prefix[i]) }
            return best > 0 ? BestPower(seconds: d, watts: best / Double(k)) : nil
        }
    }

    /// Climbing per kilometre from altitude and speed: distance is integrated from speed, altitude
    /// is smoothed over three buckets so barometer noise doesn't add up. Index = kilometre.
    public static func elevationGainPerKm(_ streams: ActivityStreams) -> [Double]? {
        guard let alt = streams.series("altitude"), let speed = streams.series("speed") else { return nil }
        let n = min(alt.count, speed.count)
        guard n > 2 else { return nil }
        // Smooth, carrying the last known altitude over gaps.
        var filled: [Double?] = []
        var last: Double?
        for i in 0..<n { if let a = alt[i] { last = a }; filled.append(last) }
        var smooth: [Double?] = []
        for i in 0..<n {
            let w = (max(i - 1, 0)...min(i + 1, n - 1)).compactMap { filled[$0] }
            smooth.append(w.isEmpty ? nil : w.reduce(0, +) / Double(w.count))
        }
        var out: [Double] = []
        var dist = 0.0
        var prev: Double?
        for i in 0..<n {
            dist += max(speed[i] ?? 0, 0) * streams.bucketSec
            let km = Int(dist / 1000)
            while out.count <= km { out.append(0) }
            if let a = smooth[i] {
                if let p = prev, a > p { out[km] += a - p }
                prev = a
            }
        }
        return out
    }
}
