import Foundation
import Accelerate

// MARK: - FeatureVector
//
// A fixed-length array of 45 Double features extracted from one 0.5-second
// sensor window.  The order here is canonical — it must match exactly the
// column order in the Python training CSV.  Never reorder without updating
// the Python feature extraction script simultaneously.
//
// Feature groups and their index ranges:
//   [0-2]   Acceleration per-axis mean
//   [3-5]   Acceleration per-axis std
//   [6-8]   Acceleration per-axis min
//   [9-11]  Acceleration per-axis max
//   [12]    Acceleration magnitude mean
//   [13]    Acceleration magnitude std
//   [14]    Acceleration magnitude max
//   [15]    Acceleration magnitude energy
//   [16]    Acceleration jerk magnitude mean
//   [17]    Acceleration jerk magnitude max
//   [18]    Acceleration signal energy
//   [19]    Acceleration zero-crossing rate
//   [20-22] Rotation per-axis mean
//   [23-25] Rotation per-axis std
//   [26]    Rotation magnitude mean
//   [27]    Rotation magnitude std
//   [28]    Rotation magnitude max
//   [29]    Angular jerk magnitude mean
//   [30]    Angular jerk magnitude max
//   [31]    Dominant axis ratio (rotation)
//   [32]    Pitch mean
//   [33]    Roll mean
//   [34]    Pitch drift rate  (deg/s equivalent, from attitude derivative)
//   [35]    Roll drift rate
//   [36]    Pitch drift acceleration (second derivative)
//   [37]    Roll drift acceleration
//   [38]    Attitude instability (RMS of pitch+roll combined derivative)
//   [39]    Pressure delta over window (kPa)
//   [40]    Pressure rate of change (kPa/s)
//   [41]    Relative altitude delta (m)
//   [42]    Acc-rotation magnitude correlation
//   [43]    Acc magnitude RMS
//   [44]    Rotation magnitude RMS

struct FeatureVector {
    static let count = 45

    let values: [Double]

    subscript(index: Int) -> Double { values[index] }

    /// Returns the feature names in canonical order. Used for CSV headers
    /// and CoreML model input validation.
    static let names: [String] = [
        "acc_x_mean", "acc_y_mean", "acc_z_mean",
        "acc_x_std",  "acc_y_std",  "acc_z_std",
        "acc_x_min",  "acc_y_min",  "acc_z_min",
        "acc_x_max",  "acc_y_max",  "acc_z_max",
        "acc_mag_mean", "acc_mag_std", "acc_mag_max", "acc_mag_energy",
        "acc_jerk_mag_mean", "acc_jerk_mag_max",
        "acc_energy", "acc_zcr",
        "rot_x_mean", "rot_y_mean", "rot_z_mean",
        "rot_x_std",  "rot_y_std",  "rot_z_std",
        "rot_mag_mean", "rot_mag_std", "rot_mag_max",
        "ang_jerk_mag_mean", "ang_jerk_mag_max",
        "dominant_axis_ratio",
        "pitch_mean", "roll_mean",
        "pitch_drift_rate", "roll_drift_rate",
        "pitch_drift_accel", "roll_drift_accel",
        "attitude_instability",
        "pressure_delta", "pressure_rate",
        "altitude_delta",
        "acc_rot_correlation",
        "acc_mag_rms",
        "rot_mag_rms"
    ]
}

// MARK: - WindowBuffers
//
// All sensor data for a single extraction window, held as TripleBuffers
// and scalar histories so the extractor has everything it needs in one place.

struct WindowBuffers {
    var acc: TripleBuffer
    var rot: TripleBuffer
    var pitch: CircularBuffer
    var roll: CircularBuffer
    var pressureHistory: CircularBuffer
    var altitudeHistory: CircularBuffer

    let capacity: Int
    let sampleRate: Double  // Hz at which this window was recorded

    init(capacity: Int, sampleRate: Double) {
        self.capacity   = capacity
        self.sampleRate = sampleRate
        acc             = TripleBuffer(capacity: capacity)
        rot             = TripleBuffer(capacity: capacity)
        pitch           = CircularBuffer(capacity: capacity)
        roll            = CircularBuffer(capacity: capacity)
        pressureHistory = CircularBuffer(capacity: capacity)
        altitudeHistory = CircularBuffer(capacity: capacity)
    }

    mutating func append(_ sample: SensorSample) {
        acc.append(x: sample.accX, y: sample.accY, z: sample.accZ)
        rot.append(x: sample.rotX, y: sample.rotY, z: sample.rotZ)
        pitch.append(sample.pitch)
        roll.append(sample.roll)
        pressureHistory.append(sample.pressure)
        altitudeHistory.append(sample.relativeAltitude)
    }

    mutating func reset() {
        acc.reset()
        rot.reset()
        pitch.reset()
        roll.reset()
        pressureHistory.reset()
        altitudeHistory.reset()
    }

    var isFull: Bool { acc.isFull }
    var count: Int   { acc.count  }
}

// MARK: - WindowBuffers index subscripts
//
// Used by MotionViewModel.rollActiveWindow() to copy the second half of the
// active window into a fresh buffer (50% overlap between extractions).
// Forwarded directly to the underlying CircularBuffer subscripts.

extension WindowBuffers {
    /// Chronological read-only access into pressureHistory.
    func pressure(at index: Int) -> Double { pressureHistory[index] }
    /// Chronological read-only access into altitudeHistory.
    func altitude(at index: Int) -> Double { altitudeHistory[index] }
}

// MARK: - FeatureExtractor
//
// Stateless namespace.  All methods are static so callers never need to
// instantiate it — just call FeatureExtractor.extract(from:).
//
// All heavy arithmetic delegates to Accelerate/vDSP so it runs on the
// vector ALU.  On an A15 or later, a full extraction over 30 samples
// (0.5 s at 60 Hz) completes in well under 1 ms.

enum FeatureExtractor {

    // MARK: - Primary Entry Point

    /// Extract a FeatureVector from a fully-populated WindowBuffers.
    /// Returns nil if the window contains fewer samples than its declared
    /// capacity (i.e. the buffer is not yet full).
    static func extract(from window: WindowBuffers) -> FeatureVector? {
        guard window.isFull else { return nil }

        let sr = window.sampleRate

        // ── Acceleration ──────────────────────────────────────────────────

        let accXv = window.acc.x.contiguousValues()
        let accYv = window.acc.y.contiguousValues()
        let accZv = window.acc.z.contiguousValues()

        let accXMean = vDSP.mean(accXv)
        let accYMean = vDSP.mean(accYv)
        let accZMean = vDSP.mean(accZv)

        let accXStd  = std(accXv)
        let accYStd  = std(accYv)
        let accZStd  = std(accZv)

        let accXMin  = min(accXv)
        let accYMin  = min(accYv)
        let accZMin  = min(accZv)

        let accXMax  = max(accXv)
        let accYMax  = max(accYv)
        let accZMax  = max(accZv)

        let accMags  = window.acc.magnitudeValues()
        let accMagMean   = vDSP.mean(accMags)
        let accMagStd    = std(accMags)
        let accMagMax    = max(accMags)
        let accMagEnergy = energy(accMags)

        // Jerk = derivative of acceleration.
        // Compute jerk on magnitude so direction cancels out.
        let accMagDeriv  = derivative(accMags, sampleRate: sr)
        let accJerkMags  = accMagDeriv.map { abs($0) }
        let accJerkMean  = accJerkMags.isEmpty ? 0.0 : vDSP.mean(accJerkMags)
        let accJerkMax   = accJerkMags.isEmpty ? 0.0 : max(accJerkMags)

        let accEnergy    = window.acc.magnitudeEnergy()
        let accZCR       = window.acc.x.zeroCrossingRate()   // x-axis representative

        // ── Rotation ──────────────────────────────────────────────────────

        let rotXv = window.rot.x.contiguousValues()
        let rotYv = window.rot.y.contiguousValues()
        let rotZv = window.rot.z.contiguousValues()

        let rotXMean = vDSP.mean(rotXv)
        let rotYMean = vDSP.mean(rotYv)
        let rotZMean = vDSP.mean(rotZv)

        let rotXStd  = std(rotXv)
        let rotYStd  = std(rotYv)
        let rotZStd  = std(rotZv)

        let rotMags  = window.rot.magnitudeValues()
        let rotMagMean = vDSP.mean(rotMags)
        let rotMagStd  = std(rotMags)
        let rotMagMax  = max(rotMags)

        // Angular jerk: derivative of rotation magnitude
        let rotMagDeriv   = derivative(rotMags, sampleRate: sr)
        let angJerkMags   = rotMagDeriv.map { abs($0) }
        let angJerkMean   = angJerkMags.isEmpty ? 0.0 : vDSP.mean(angJerkMags)
        let angJerkMax    = angJerkMags.isEmpty ? 0.0 : max(angJerkMags)

        // Dominant axis ratio: ~1.0 = uniaxial (intentional), ~0.33 = chaotic
        let dominantAxisRatio = window.rot.dominantAxisRatio()

        // ── Attitude ──────────────────────────────────────────────────────

        let pitchV   = window.pitch.contiguousValues()
        let rollV    = window.roll.contiguousValues()

        let pitchMean = vDSP.mean(pitchV)
        let rollMean  = vDSP.mean(rollV)

        // Drift rate: first derivative of attitude angle (rad/s)
        let pitchDeriv     = derivative(pitchV, sampleRate: sr)
        let rollDeriv      = derivative(rollV,  sampleRate: sr)
        let pitchDriftRate = pitchDeriv.isEmpty ? 0.0 : vDSP.mean(pitchDeriv.map { abs($0) })
        let rollDriftRate  = rollDeriv.isEmpty  ? 0.0 : vDSP.mean(rollDeriv.map  { abs($0) })

        // Drift acceleration: second derivative (rad/s²)
        let pitchSecond       = derivative(pitchDeriv, sampleRate: sr)
        let rollSecond        = derivative(rollDeriv,  sampleRate: sr)
        let pitchDriftAccel   = pitchSecond.isEmpty ? 0.0 : vDSP.mean(pitchSecond.map { abs($0) })
        let rollDriftAccel    = rollSecond.isEmpty  ? 0.0 : vDSP.mean(rollSecond.map  { abs($0) })

        // Attitude instability: RMS of combined pitch + roll derivatives
        let combinedDeriv     = zip(pitchDeriv, rollDeriv).map { sqrt($0*$0 + $1*$1) }
        let attitudeInstab    = rms(combinedDeriv)

        // ── Barometer / Altimeter ─────────────────────────────────────────

        let pressureVals   = window.pressureHistory.contiguousValues()
        let altitudeVals   = window.altitudeHistory.contiguousValues()

        let pressureDelta  = pressureVals.isEmpty  ? 0.0 : (pressureVals.last! - pressureVals.first!)
        let pressureRate   = pressureVals.count > 1
                            ? pressureDelta / (Double(pressureVals.count - 1) / sr)
                            : 0.0
        let altitudeDelta  = altitudeVals.isEmpty  ? 0.0 : (altitudeVals.last! - altitudeVals.first!)

        // ── Cross-signal ──────────────────────────────────────────────────

        // Correlation between acc magnitude and rotation magnitude.
        // High correlation during a fall: both spike simultaneously.
        // Low correlation during intentional gesture: acc spikes, rot stays low.
        let accRotCorr = pearsonCorrelation(accMags, rotMags)

        // ── RMS features ─────────────────────────────────────────────────

        let accMagRMS = rms(accMags)
        let rotMagRMS = rms(rotMags)

        // ── Assemble ──────────────────────────────────────────────────────

        let values: [Double] = [
            // [0-2]  acc per-axis mean
            accXMean, accYMean, accZMean,
            // [3-5]  acc per-axis std
            accXStd, accYStd, accZStd,
            // [6-8]  acc per-axis min
            accXMin, accYMin, accZMin,
            // [9-11] acc per-axis max
            accXMax, accYMax, accZMax,
            // [12-15] acc magnitude stats
            accMagMean, accMagStd, accMagMax, accMagEnergy,
            // [16-17] acc jerk
            accJerkMean, accJerkMax,
            // [18-19] acc energy, ZCR
            accEnergy, accZCR,
            // [20-22] rot per-axis mean
            rotXMean, rotYMean, rotZMean,
            // [23-25] rot per-axis std
            rotXStd, rotYStd, rotZStd,
            // [26-28] rot magnitude stats
            rotMagMean, rotMagStd, rotMagMax,
            // [29-30] angular jerk
            angJerkMean, angJerkMax,
            // [31] dominant axis ratio
            dominantAxisRatio,
            // [32-33] attitude mean
            pitchMean, rollMean,
            // [34-35] attitude drift rate
            pitchDriftRate, rollDriftRate,
            // [36-37] attitude drift acceleration
            pitchDriftAccel, rollDriftAccel,
            // [38] attitude instability
            attitudeInstab,
            // [39-41] barometer / altitude
            pressureDelta, pressureRate, altitudeDelta,
            // [42] cross-signal correlation
            accRotCorr,
            // [43-44] RMS
            accMagRMS, rotMagRMS
        ]

        assert(values.count == FeatureVector.count,
               "Feature count mismatch: got \(values.count), expected \(FeatureVector.count)")

        return FeatureVector(values: values)
    }

    // MARK: - Anomaly Gate Features
    //
    // The anomaly gate runs at 15 Hz and needs a fast, low-dimensional
    // feature vector — not the full 45. These 6 features cover the most
    // discriminative dimensions for a z-score outlier check.

    static func extractAnomalyFeatures(from window: WindowBuffers) -> [Double]? {
        guard window.count >= window.capacity / 2 else { return nil }  // need at least half-full

        let accMags = window.acc.magnitudeValues()
        let rotMags = window.rot.magnitudeValues()

        let pitchV  = window.pitch.contiguousValues()
        let rollV   = window.roll.contiguousValues()

        guard !accMags.isEmpty, !rotMags.isEmpty,
              !pitchV.isEmpty,  !rollV.isEmpty else { return nil }

        let accMagMean = vDSP.mean(accMags)
        let accMagStd  = std(accMags)
        let rotMagMean = vDSP.mean(rotMags)
        let rotMagStd  = std(rotMags)

        let pitchDeriv    = derivative(pitchV, sampleRate: window.sampleRate)
        let rollDeriv     = derivative(rollV,  sampleRate: window.sampleRate)
        let pitchDriftAbs = pitchDeriv.isEmpty ? 0.0 : vDSP.mean(pitchDeriv.map { abs($0) })
        let rollDriftAbs  = rollDeriv.isEmpty  ? 0.0 : vDSP.mean(rollDeriv.map  { abs($0) })

        return [
            accMagMean, accMagStd,
            rotMagMean, rotMagStd,
            pitchDriftAbs, rollDriftAbs
        ]
    }

    // MARK: - Baseline Statistics
    //
    // Compute the rolling mean and standard deviation of each anomaly feature
    // over a long ambient window (e.g. 300 samples = 20 seconds at 15 Hz).
    // Used by the z-score anomaly gate.

    struct BaselineStats {
        let means: [Double]
        let stds: [Double]
        let featureCount: Int

        /// Z-score for each feature of an incoming sample vs this baseline.
        /// Returns an empty array if dimensions mismatch.
        func zScores(for features: [Double]) -> [Double] {
            guard features.count == featureCount else { return [] }
            return zip(zip(features, means), stds).map { pair, sigma -> Double in
                let (x, mu) = pair
                return sigma > 0 ? abs(x - mu) / sigma : 0
            }
        }

        /// Max z-score across all features: single scalar anomaly score.
        func maxZScore(for features: [Double]) -> Double {
            zScores(for: features).max() ?? 0
        }
    }

    // MARK: - vDSP Helpers (private)

    private static func std(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        var meanOut: Double = 0
        var stdOut: Double = 0
        vDSP_normalizeD(values, 1, nil, 1, &meanOut, &stdOut, vDSP_Length(values.count))
        return stdOut
    }

    private static func min(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        var result: Double = 0
        vDSP_minvD(values, 1, &result, vDSP_Length(values.count))
        return result
    }

    private static func max(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        var result: Double = 0
        vDSP_maxvD(values, 1, &result, vDSP_Length(values.count))
        return result
    }

    private static func energy(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        var result: Double = 0
        vDSP_svesqD(values, 1, &result, vDSP_Length(values.count))
        return result
    }

    private static func rms(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        var result: Double = 0
        vDSP_rmsqvD(values, 1, &result, vDSP_Length(values.count))
        return result
    }

    /// Finite-difference first derivative, scaled by sampleRate.
    private static func derivative(_ values: [Double], sampleRate: Double) -> [Double] {
        guard values.count > 1 else { return [] }
        var result = [Double](repeating: 0, count: values.count - 1)
        for i in 0..<result.count {
            result[i] = (values[i + 1] - values[i]) * sampleRate
        }
        return result
    }

    /// Pearson correlation between two equal-length arrays.
    private static func pearsonCorrelation(_ x: [Double], _ y: [Double]) -> Double {
        guard x.count == y.count, x.count > 1 else { return 0 }
        let n = vDSP_Length(x.count)
        let mx = vDSP.mean(x)
        let my = vDSP.mean(y)

        var negMx = -mx
        var negMy = -my
        var xc = [Double](repeating: 0, count: x.count)
        var yc = [Double](repeating: 0, count: y.count)
        vDSP_vsaddD(x, 1, &negMx, &xc, 1, n)
        vDSP_vsaddD(y, 1, &negMy, &yc, 1, n)

        var dot: Double = 0
        vDSP_dotprD(xc, 1, yc, 1, &dot, n)

        var ex: Double = 0
        var ey: Double = 0
        vDSP_svesqD(xc, 1, &ex, n)
        vDSP_svesqD(yc, 1, &ey, n)

        let denom = sqrt(ex * ey)
        return denom == 0 ? 0 : dot / denom
    }
}

// MARK: - RollingBaselineAccumulator
//
// Maintains a per-feature set of CircularBuffers long enough to compute a
// stable baseline mean and std.  Used by the anomaly gate at ambient rate.

final class RollingBaselineAccumulator {

    private let featureCount: Int
    private var buffers: [CircularBuffer]
    private let windowSize: Int

    /// windowSize: number of anomaly feature samples to keep.
    /// At 15 Hz, 300 samples = 20 seconds of baseline.
    init(featureCount: Int, windowSize: Int = 300) {
        self.featureCount = featureCount
        self.windowSize   = windowSize
        self.buffers      = (0..<featureCount).map { _ in CircularBuffer(capacity: windowSize) }
    }

    /// Append a new feature vector to the rolling window.
    func append(_ features: [Double]) {
        guard features.count == featureCount else { return }
        for (i, value) in features.enumerated() {
            buffers[i].append(value)
        }
    }

    /// True when at least half the baseline window is populated.
    var isReady: Bool {
        buffers.first.map { $0.count >= windowSize / 2 } ?? false
    }

    /// Compute current baseline statistics.  Returns nil if not yet ready.
    func currentStats() -> FeatureExtractor.BaselineStats? {
        guard isReady else { return nil }
        let means = buffers.map { $0.mean() }
        let stds  = buffers.map { $0.standardDeviation() }
        return FeatureExtractor.BaselineStats(
            means: means,
            stds: stds,
            featureCount: featureCount
        )
    }

    func reset() {
        for i in buffers.indices { buffers[i].reset() }
    }
}
