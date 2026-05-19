import Foundation
import Accelerate

// MARK: - CircularBuffer
//
// A fixed-capacity, O(1)-insert ring buffer of Double values backed by a
// ContiguousArray for cache-friendly access. All statistical operations
// delegate to vDSP so they execute on the vector ALU — typically 10-20x
// faster than scalar Swift loops on the same data.
//
// Thread-safety: NOT thread-safe. All reads and writes must occur on the
// same queue (the pipeline's dedicated serial DispatchQueue).

struct CircularBuffer {

    // MARK: Storage

    private var storage: ContiguousArray<Double>
    private var head: Int = 0          // index of the oldest element
    private(set) var count: Int = 0    // number of valid elements (≤ capacity)
    let capacity: Int

    // MARK: Init

    init(capacity: Int) {
        precondition(capacity > 1, "CircularBuffer capacity must be > 1")
        self.capacity = capacity
        self.storage = ContiguousArray(repeating: 0.0, count: capacity)
    }

    // MARK: - Mutation

    /// Append a value. When the buffer is full, the oldest element is silently
    /// overwritten and the read head advances.
    mutating func append(_ value: Double) {
        let writeIndex = (head + count) % capacity
        storage[writeIndex] = value
        if count < capacity {
            count += 1
        } else {
            head = (head + 1) % capacity
        }
    }

    /// Wipe all elements and reset counters.
    mutating func reset() {
        storage = ContiguousArray(repeating: 0.0, count: capacity)
        head = 0
        count = 0
    }

    var isFull: Bool { count == capacity }

    // MARK: - Contiguous Access
    //
    // vDSP expects a flat, contiguous array in chronological order. When
    // the ring wraps we must linearise first. Callers that need multiple
    // statistics should call contiguousValues() once and pass it to each
    // helper to avoid repeated copies.

    func contiguousValues() -> [Double] {
        guard count > 0 else { return [] }
        if head == 0 {
            return Array(storage[0..<count])
        }
        var result = [Double]()
        result.reserveCapacity(count)
        let tailLength = min(capacity - head, count)
        result.append(contentsOf: storage[head..<(head + tailLength)])
        let headLength = count - tailLength
        if headLength > 0 {
            result.append(contentsOf: storage[0..<headLength])
        }
        return result
    }

    // MARK: - vDSP Statistics

    /// Arithmetic mean.
    func mean() -> Double {
        guard count > 0 else { return 0 }
        return vDSP.mean(contiguousValues())
    }

    /// Population standard deviation.
    func standardDeviation() -> Double {
        guard count > 1 else { return 0 }
        let values = contiguousValues()
        var meanOut: Double = 0
        var stdOut: Double = 0
        vDSP_normalizeD(values, 1, nil, 1, &meanOut, &stdOut, vDSP_Length(values.count))
        return stdOut
    }

    /// Root-mean-square.
    func rms() -> Double {
        guard count > 0 else { return 0 }
        let values = contiguousValues()
        var result: Double = 0
        vDSP_rmsqvD(values, 1, &result, vDSP_Length(values.count))
        return result
    }

    /// Minimum value.
    func minimum() -> Double {
        guard count > 0 else { return 0 }
        let values = contiguousValues()
        var result: Double = 0
        vDSP_minvD(values, 1, &result, vDSP_Length(values.count))
        return result
    }

    /// Maximum value.
    func maximum() -> Double {
        guard count > 0 else { return 0 }
        let values = contiguousValues()
        var result: Double = 0
        vDSP_maxvD(values, 1, &result, vDSP_Length(values.count))
        return result
    }

    /// Signal energy: ∑xᵢ².
    func energy() -> Double {
        guard count > 0 else { return 0 }
        let values = contiguousValues()
        var result: Double = 0
        vDSP_svesqD(values, 1, &result, vDSP_Length(values.count))
        return result
    }

    /// Zero-crossing rate: sign changes / (count − 1). Ranges [0, 1].
    /// High values indicate chaotic / noisy motion.
    func zeroCrossingRate() -> Double {
        guard count > 1 else { return 0 }
        let values = contiguousValues()
        var crossings = 0
        for i in 1..<values.count where values[i - 1] * values[i] < 0 {
            crossings += 1
        }
        return Double(crossings) / Double(values.count - 1)
    }

    /// First-order finite-difference derivative array, scaled by sampleRate.
    /// derivative[i] = (values[i+1] − values[i]) × sampleRate
    /// Used to compute jerk (derivative of acceleration).
    func derivative(sampleRate: Double) -> [Double] {
        guard count > 1 else { return [] }
        let values = contiguousValues()
        var result = [Double](repeating: 0, count: values.count - 1)
        for i in 0..<result.count {
            result[i] = (values[i + 1] - values[i]) * sampleRate
        }
        return result
    }

    /// Pearson correlation coefficient with another equal-length buffer.
    func correlation(with other: CircularBuffer) -> Double {
        guard count == other.count, count > 1 else { return 0 }
        let x = contiguousValues()
        let y = other.contiguousValues()
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

        var normX: Double = 0
        var normY: Double = 0
        vDSP_svesqD(xc, 1, &normX, n)
        vDSP_svesqD(yc, 1, &normY, n)

        let denom = sqrt(normX * normY)
        return denom == 0 ? 0 : dot / denom
    }

    // MARK: - Subscript (read-only, chronological order)

    subscript(index: Int) -> Double {
        precondition(index >= 0 && index < count)
        return storage[(head + index) % capacity]
    }
}

// MARK: - TripleBuffer
//
// Bundles three CircularBuffers for X, Y, Z sensor axes into one unit.
// The feature extractor always receives a TripleBuffer so callers never
// manage three loose buffers independently.

struct TripleBuffer {

    var x: CircularBuffer
    var y: CircularBuffer
    var z: CircularBuffer

    init(capacity: Int) {
        x = CircularBuffer(capacity: capacity)
        y = CircularBuffer(capacity: capacity)
        z = CircularBuffer(capacity: capacity)
    }

    mutating func append(x xv: Double, y yv: Double, z zv: Double) {
        x.append(xv)
        y.append(yv)
        z.append(zv)
    }

    mutating func reset() {
        x.reset()
        y.reset()
        z.reset()
    }

    var count: Int { x.count }
    var isFull: Bool { x.isFull }
    var capacity: Int { x.capacity }

    // MARK: Derived magnitude helpers

    /// Resultant magnitude for each sample: √(x² + y² + z²).
    func magnitudeValues() -> [Double] {
        let xv = x.contiguousValues()
        let yv = y.contiguousValues()
        let zv = z.contiguousValues()
        guard xv.count == yv.count, xv.count == zv.count else { return [] }
        var result = [Double](repeating: 0.0, count: xv.count)
        for i in 0..<xv.count {
            let dx = xv[i], dy = yv[i], dz = zv[i]
            result[i] = sqrt(dx * dx + dy * dy + dz * dz)
        }
        return result
    }

    func magnitudeMean() -> Double {
        let mags = magnitudeValues()
        guard !mags.isEmpty else { return 0 }
        return vDSP.mean(mags)
    }

    func magnitudeStd() -> Double {
        let mags = magnitudeValues()
        guard mags.count > 1 else { return 0 }
        var meanOut: Double = 0
        var stdOut: Double = 0
        vDSP_normalizeD(mags, 1, nil, 1, &meanOut, &stdOut, vDSP_Length(mags.count))
        return stdOut
    }

    func magnitudeMax() -> Double {
        let mags = magnitudeValues()
        guard !mags.isEmpty else { return 0 }
        var result: Double = 0
        vDSP_maxvD(mags, 1, &result, vDSP_Length(mags.count))
        return result
    }

    func magnitudeEnergy() -> Double {
        let mags = magnitudeValues()
        guard !mags.isEmpty else { return 0 }
        var result: Double = 0
        vDSP_svesqD(mags, 1, &result, vDSP_Length(mags.count))
        return result
    }

    /// Dominant axis ratio: fraction of total variance held by the single
    /// strongest axis. ~1.0 → uniaxial (intentional gesture). ~0.33 →
    /// tri-axial chaos (fumble / fall).
    func dominantAxisRatio() -> Double {
        let vx = x.standardDeviation()
        let vy = y.standardDeviation()
        let vz = z.standardDeviation()
        let total = vx + vy + vz
        guard total > 0 else { return 1.0 }
        return max(vx, max(vy, vz)) / total
    }
}
