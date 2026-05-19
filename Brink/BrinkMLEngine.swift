import Foundation
import CoreML
import Accelerate

// MARK: - BrinkMLEngine
//
// Owns all ML inference for the Brink detection pipeline.
// This class replaces the heuristic sigmoid scorer in MotionViewModel
// with a production four-component system:
//
//   Component 1 — Mahalanobis Anomaly Gate
//                 Multivariate distance check using Ledoit-Wolf precision
//                 matrix fit on normal training data.  Replaces the naive
//                 z-score gate with a statistically principled detector that
//                 handles feature correlations.  Runs at 15 Hz.
//
//   Component 2 — XGBoost GBT Classifier (CoreML)
//                 Primary risk scorer.  Runs on the 45-feature vector from
//                 the 0.5-second active window.  Outputs a raw probability.
//
//   Component 3 — Isotonic Calibration
//                 Applies the isotonic regression lookup table fit during
//                 training to convert the raw GBT probability to a true
//                 calibrated probability.  Pure Swift interpolation — no
//                 additional CoreML model needed.
//
//   Component 4 — One-Class SVM Veto (CoreML or manual RBF)
//                 Independent normal-data classifier.  If it says this
//                 sample looks like normal motion, the alert is hard-vetoed
//                 regardless of GBT score.  Two independent models must
//                 agree before any alert fires.
//
//   Component 5 — CUSUM Detector
//                 Replaces the exponential smoothing + persistence counter.
//                 Mathematically optimal sequential change-point detector
//                 with proven false-alarm properties (controlled ARL0).
//                 Parameters (k, h) per sensitivity level are loaded from
//                 brink_runtime_params.json.
//
// Thread-safety: all public methods are safe to call from pipelineQueue.
// No locking needed — callers serialise via the pipeline's serial queue.

final class BrinkMLEngine {

    // MARK: - Runtime Parameters

    struct RuntimeParams: Decodable {
        let featureNames:       [String]
        let anomalyFeatureNames: [String]
        let scaler:             ScalerParams
        let isotonicX:          [Double]
        let isotonicY:          [Double]
        let optimalThreshold:   Double
        let vetoThreshold:      Double
        let mahalanobisGate:    MahalanobisGateParams
        let cusum:              [String: CUSUMParams]

        struct ScalerParams: Decodable {
            let center: [Double]
            let scale:  [Double]
        }
        struct MahalanobisGateParams: Decodable {
            let mean:        [Double]
            let precision:   [[Double]]   // inverse covariance matrix
            let threshold99: Double
            enum CodingKeys: String, CodingKey {
                case mean, precision
                case threshold99 = "threshold_99"
            }
        }
        struct CUSUMParams: Decodable {
            let k: Double
            let h: Double
        }
        enum CodingKeys: String, CodingKey {
            case featureNames        = "feature_names"
            case anomalyFeatureNames = "anomaly_feature_names"
            case scaler, cusum
            case isotonicX           = "isotonic_x"
            case isotonicY           = "isotonic_y"
            case optimalThreshold    = "optimal_threshold"
            case vetoThreshold       = "veto_threshold"
            case mahalanobisGate     = "mahalanobis_gate"
        }
    }

    // MARK: - CUSUM State

    /// One-sided upper CUSUM accumulator.
    /// S_n = max(0, S_{n-1} + (p_n - k))
    /// Alert when S_n >= h.
    private struct CUSUMState {
        var S: Double = 0.0
        var k: Double = 0.20
        var h: Double = 2.00

        mutating func update(_ probability: Double) -> Bool {
            S = max(0.0, S + probability - k)
            return S >= h
        }

        mutating func reset() { S = 0.0 }

        /// Partial credit: return normalised accumulation as a continuous
        /// risk score in [0, 1] for UI display even before alert threshold.
        var normalisedScore: Double { min(S / h, 1.0) }
    }

    // MARK: - Properties

    private var params: RuntimeParams?
    private var isLoaded: Bool = false
    private var loadError: String? = nil

    // CoreML models — nil until loaded
    private var gbtModel:  MLModel? = nil
    private var vetoModel: MLModel? = nil

    // Veto SVM manual fallback (when CoreML export failed)
    private var svmManual: SVMManualParams? = nil

    // Scaled feature cache (avoids re-allocating on every inference)
    private var scaledBuffer = [Double](repeating: 0.0, count: FeatureVector.count)

    // CUSUM state — reset on alert, sensitivity change, or calibration
    private var cusumState = CUSUMState()

    // Cooldown: frames to suppress after an alert
    private var cooldownFramesRemaining: Int = 0
    private let cooldownFrames: Int = 1800   // 30 s × 60 Hz

    // MARK: - Initialisation

    init() {
        loadFromBundle()
    }

    // MARK: - Bundle Loading

    private func loadFromBundle() {
        // Load runtime parameters JSON
        guard let paramsURL = Bundle.main.url(
            forResource: "brink_runtime_params",
            withExtension: "json"
        ) else {
            loadError = "brink_runtime_params.json not found in bundle"
            return
        }

        do {
            let data   = try Data(contentsOf: paramsURL)
            let decoded = try JSONDecoder().decode(RuntimeParams.self, from: data)
            params = decoded

            // Validate dimensions
            guard decoded.scaler.center.count == FeatureVector.count,
                  decoded.scaler.scale.count  == FeatureVector.count else {
                loadError = "Scaler dimension mismatch: expected \(FeatureVector.count)"
                return
            }
        } catch {
            loadError = "Failed to decode runtime params: \(error)"
            return
        }

        // Load CoreML models
        loadGBTModel()
        loadVetoModel()

        isLoaded = true
        print("[BrinkMLEngine] Loaded successfully.")
    }

    private func loadGBTModel() {
        guard let url = Bundle.main.url(
            forResource: "BrinkClassifier",
            withExtension: "mlpackage"
        ) ?? Bundle.main.url(
            forResource: "BrinkClassifier",
            withExtension: "mlmodelc"
        ) else {
            loadError = (loadError ?? "") + " GBT model not found."
            return
        }

        do {
            let config         = MLModelConfiguration()
            config.computeUnits = .cpuAndNeuralEngine  // prefer ANE, fall back to CPU
            gbtModel           = try MLModel(contentsOf: url, configuration: config)
        } catch {
            loadError = (loadError ?? "") + " GBT load error: \(error)"
        }
    }

    private func loadVetoModel() {
        if let url = Bundle.main.url(
            forResource: "BrinkVetoClassifier",
            withExtension: "mlpackage"
        ) ?? Bundle.main.url(
            forResource: "BrinkVetoClassifier",
            withExtension: "mlmodelc"
        ) {
            do {
                let config          = MLModelConfiguration()
                config.computeUnits = .cpuOnly  // SVM doesn't benefit from ANE
                vetoModel           = try MLModel(contentsOf: url, configuration: config)
                return
            } catch {
                print("[BrinkMLEngine] Veto CoreML load failed: \(error) — trying manual JSON")
            }
        }

        // Fallback: load manual SVM JSON
        if let url = Bundle.main.url(forResource: "brink_svm_manual", withExtension: "json") {
            svmManual = SVMManualParams(jsonURL: url)
        }
    }

    // MARK: - Sensitivity

    func configureCUSUM(sensitivity: SensitivityLevel) {
        guard let params else { return }
        let key: String
        switch sensitivity {
        case .low:      key = "low"
        case .balanced: key = "balanced"
        case .high:     key = "high"
        }
        if let cp = params.cusum[key] {
            cusumState.k = cp.k
            cusumState.h = cp.h
        }
        cusumState.reset()
    }

    // MARK: - Mahalanobis Anomaly Gate

    /// Returns the Mahalanobis distance of anomalyFeatures from the
    /// normal-class centroid.  Exceeding params.mahalanobisGate.threshold99
    /// triggers high-frequency sampling.
    ///
    /// Uses Accelerate for the matrix-vector multiply (precision × delta).
    /// For the 6×6 precision matrix this is 36 multiply-adds — negligible.
    func mahalanobisDistance(anomalyFeatures: [Double]) -> Double {
        guard let params, anomalyFeatures.count == params.mahalanobisGate.mean.count
        else { return 0 }

        let n   = anomalyFeatures.count
        let mu  = params.mahalanobisGate.mean
        let prec = params.mahalanobisGate.precision   // n×n matrix, row-major

        // delta = x - mu
        var delta = [Double](repeating: 0, count: n)
        for i in 0..<n { delta[i] = anomalyFeatures[i] - mu[i] }

        // temp = precision × delta  (matrix-vector product)
        // precision is stored as [[Double]] (array of rows)
        var temp = [Double](repeating: 0, count: n)
        for row in 0..<n {
            var dot: Double = 0
            vDSP_dotprD(prec[row], 1, delta, 1, &dot, vDSP_Length(n))
            temp[row] = dot
        }

        // distance² = delta^T × temp
        var distSq: Double = 0
        vDSP_dotprD(delta, 1, temp, 1, &distSq, vDSP_Length(n))

        return sqrt(max(distSq, 0))
    }

    var mahalanobisThreshold: Double {
        params?.mahalanobisGate.threshold99 ?? 3.5
    }

    // MARK: - Primary Inference

    /// Run the full inference pipeline on one FeatureVector.
    /// Returns an InferenceResult containing the calibrated probability,
    /// the CUSUM state, the veto decision, and the final should-alert flag.
    ///
    /// Call this from pipelineQueue only.
    func infer(
        featureVector: FeatureVector,
        sensitivity: SensitivityLevel
    ) -> InferenceResult {
        guard isLoaded, let params else {
            return InferenceResult.unavailable
        }

        if cooldownFramesRemaining > 0 {
            cooldownFramesRemaining -= 1
            return InferenceResult(
                rawProbability:        0,
                calibratedProbability: 0,
                cusumScore:            0,
                isVetoed:              true,
                shouldAlert:           false,
                stage:                 .cooldown
            )
        }

        // ── Step 1: Scale features ────────────────────────────────────────
        let center = params.scaler.center
        let scale  = params.scaler.scale
        let raw    = featureVector.values

        for i in 0..<FeatureVector.count {
            scaledBuffer[i] = scale[i] > 0
                ? (raw[i] - center[i]) / scale[i]
                : 0.0
        }

        // ── Step 2: GBT inference (CoreML) ───────────────────────────────
        let rawProb = runGBT(scaledFeatures: scaledBuffer) ?? heuristicFallback(raw: raw)

        // ── Step 3: Isotonic calibration ─────────────────────────────────
        let calProb = isotonicCalibrate(rawProb, xTable: params.isotonicX,
                                        yTable: params.isotonicY)

        // ── Step 4: Veto check ───────────────────────────────────────────
        let isVetoed = checkVeto(scaledFeatures: scaledBuffer, params: params)

        // ── Step 5: CUSUM update ─────────────────────────────────────────
        // Only feed non-vetoed probabilities into CUSUM.
        // A veto resets the accumulator — if the SVM says "normal", that
        // is strong evidence against an ongoing event.
        let cusumTriggered: Bool
        if isVetoed {
            cusumState.reset()
            cusumTriggered = false
        } else {
            cusumTriggered = cusumState.update(calProb)
        }

        let shouldAlert = cusumTriggered && !isVetoed

        if shouldAlert {
            cooldownFramesRemaining = cooldownFrames
            cusumState.reset()
        }

        return InferenceResult(
            rawProbability:        rawProb,
            calibratedProbability: calProb,
            cusumScore:            cusumState.normalisedScore,
            isVetoed:              isVetoed,
            shouldAlert:           shouldAlert,
            stage:                 shouldAlert ? .alert : .monitoring
        )
    }

    // MARK: - Reset

    func resetCUSUM() {
        cusumState.reset()
        cooldownFramesRemaining = 0
    }

    // MARK: - Private: CoreML GBT

    private func runGBT(scaledFeatures: [Double]) -> Double? {
        guard let model = gbtModel else { return nil }

        // Build MLFeatureProvider from the scaled feature array.
        // We use MLDictionaryFeatureProvider for compatibility with all
        // CoreML export paths (sklearn, xgboost native, etc.)
        guard let params else { return nil }
        var dict = [String: MLFeatureValue]()
        dict.reserveCapacity(FeatureVector.count)

        for (i, name) in params.featureNames.enumerated() {
            dict[name] = MLFeatureValue(double: scaledFeatures[i])
        }

        guard let provider = try? MLDictionaryFeatureProvider(dictionary: dict),
              let result   = try? model.prediction(from: provider)
        else { return nil }

        // The output feature name for probability varies by CoreML export path.
        // Try common names in order.
        let probOutputNames = [
            "fall_probabilityProbs",
            "classProbability",
            "probabilities",
            "fall_probability",
        ]
        for name in probOutputNames {
            if let val = result.featureValue(for: name) {
                if val.type == .double   { return val.doubleValue }
                if val.type == .dictionary {
                    // ClassProbability dict — key "1" = positive class
                    if let d = val.dictionaryValue as? [Int64: Double] {
                        return d[1] ?? d[Int64(1)]
                    }
                    if let d = val.dictionaryValue as? [String: Double] {
                        return d["1"]
                    }
                }
            }
        }
        return nil
    }

    // MARK: - Private: Veto

    private func checkVeto(scaledFeatures: [Double], params: RuntimeParams) -> Bool {
        // Try CoreML veto model first
        if let model = vetoModel {
            var dict = [String: MLFeatureValue]()
            for (i, name) in params.featureNames.enumerated() {
                dict[name] = MLFeatureValue(double: scaledFeatures[i])
            }
            if let provider = try? MLDictionaryFeatureProvider(dictionary: dict),
               let result   = try? model.prediction(from: provider) {
                // One-class SVM decision function output
                let score = result.featureValue(for: "normality_score")?.doubleValue
                        ?? result.featureValue(for: "score")?.doubleValue
                        ?? result.featureValue(for: "prediction")?.doubleValue
                if let s = score {
                    // Score > threshold means the sample looks normal → veto
                    return s >= params.vetoThreshold
                }
            }
        }

        // Fallback: manual RBF SVM inference
        if let svm = svmManual {
            let score = svm.decisionFunction(scaledFeatures: scaledFeatures)
            return score >= svm.vetoThreshold
        }

        // If neither veto path works, do not veto (fail open toward detection)
        return false
    }

    // MARK: - Private: Isotonic Calibration
    //
    // Piecewise-linear interpolation of the isotonic regression lookup table.
    // O(log n) via binary search on the x-table.

    private func isotonicCalibrate(
        _ rawScore: Double,
        xTable: [Double],
        yTable: [Double]
    ) -> Double {
        guard !xTable.isEmpty, xTable.count == yTable.count else { return rawScore }

        if rawScore <= xTable.first! { return yTable.first! }
        if rawScore >= xTable.last!  { return yTable.last!  }

        // Binary search for the interval [xTable[i], xTable[i+1]] containing rawScore
        var lo = 0
        var hi = xTable.count - 1
        while lo < hi - 1 {
            let mid = (lo + hi) / 2
            if xTable[mid] <= rawScore { lo = mid } else { hi = mid }
        }

        let x0 = xTable[lo], x1 = xTable[hi]
        let y0 = yTable[lo], y1 = yTable[hi]

        guard x1 > x0 else { return y0 }
        let t = (rawScore - x0) / (x1 - x0)
        return y0 + t * (y1 - y0)
    }

    // MARK: - Private: Heuristic Fallback
    //
    // Used when CoreML GBT is unavailable (e.g. first launch before model
    // is confirmed loadable, or model file missing from bundle).
    // Identical to the heuristic in MotionViewModel so the pipeline
    // degrades gracefully rather than silencing all alerts.

    private func heuristicFallback(raw: [Double]) -> Double {
        guard raw.count >= 45 else { return 0 }
        let accJerkMean     = raw[16]
        let rotMagMean      = raw[26]
        let domAxis         = raw[31]
        let pitchMean       = raw[32]
        let rollMean        = raw[33]
        let pitchDriftRate  = raw[34]
        let rollDriftRate   = raw[35]
        let pitchDriftAccel = raw[36]
        let rollDriftAccel  = raw[37]
        let pressureDelta   = raw[39]
        let accRotCorr      = raw[42]

        func sig(_ x: Double, _ c: Double, _ s: Double) -> Double {
            1.0 / (1.0 + exp(-s * (x - c)))
        }

        let tiltAngle      = sqrt(pitchMean*pitchMean + rollMean*rollMean)
        let driftRate      = max(pitchDriftRate, rollDriftRate)
        let driftAccel     = max(pitchDriftAccel, rollDriftAccel)

        let score =
            sig(accJerkMean, 2.5, 1.8)    * 0.20 +
            sig(rotMagMean,  3.0, 1.2)    * 0.12 +
            (1.0 - domAxis)               * 0.10 +
            sig(tiltAngle,   0.6, 3.5)    * 0.15 +
            sig(driftRate,   0.8, 2.5)    * 0.13 +
            sig(driftAccel,  1.5, 2.0)    * 0.12 +
            (pressureDelta < -0.05 ? sig(-pressureDelta, 0.1, 8.0) : 0) * 0.08 +
            (accRotCorr > 0.6 ? (accRotCorr - 0.6) / 0.4 : 0)           * 0.05 +
            0.05

        return min(score, 1.0)
    }
}

// MARK: - InferenceResult

struct InferenceResult {
    let rawProbability:        Double   // raw GBT output before calibration
    let calibratedProbability: Double   // isotonic-calibrated probability
    let cusumScore:            Double   // normalised CUSUM accumulation [0,1]
    let isVetoed:              Bool     // one-class SVM said "looks normal"
    let shouldAlert:           Bool     // CUSUM triggered AND not vetoed
    let stage:                 Stage

    enum Stage { case monitoring, alert, cooldown, unavailable }

    static let unavailable = InferenceResult(
        rawProbability: 0, calibratedProbability: 0,
        cusumScore: 0, isVetoed: false, shouldAlert: false, stage: .unavailable
    )

    /// Continuous risk score for UI display: CUSUM score dominates once
    /// evidence starts accumulating; calibrated probability provides the seed.
    var displayScore: Double {
        max(cusumScore, calibratedProbability * 0.4)
    }
}

// MARK: - SVMManualParams
//
// Loaded when the CoreML veto export failed.
// Performs RBF kernel evaluation:  K(x, sv) = exp(-gamma × ||x - sv||²)
// Decision: sum over support vectors of (dual_coef × K) + intercept.
// If decision > vetoThreshold → sample looks normal → veto alert.

private struct SVMManualParams {

    let supportVectors: [[Double]]
    let dualCoef:       [Double]
    let intercept:      Double
    let gamma:          Double
    let scalerCenter:   [Double]
    let scalerScale:    [Double]
    let vetoThreshold:  Double

    init?(jsonURL: URL) {
        guard let data = try? Data(contentsOf: jsonURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        guard
            let sv   = json["support_vectors"]  as? [[Double]],
            let dc   = json["dual_coef"]        as? [[Double]],
            let ic   = json["intercept"]        as? Double,
            let gm   = json["gamma"]            as? Double,
            let sc   = json["scaler_center"]    as? [Double],
            let ss   = json["scaler_scale"]     as? [Double],
            let vt   = json["veto_threshold"]   as? Double
        else { return nil }

        self.supportVectors = sv
        self.dualCoef       = dc.first ?? []
        self.intercept      = ic
        self.gamma          = gm
        self.scalerCenter   = sc
        self.scalerScale    = ss
        self.vetoThreshold  = vt
    }

    func decisionFunction(scaledFeatures: [Double]) -> Double {
        let n = scaledFeatures.count
        var decision = intercept

        for (i, sv) in supportVectors.enumerated() {
            guard i < dualCoef.count else { break }
            // ||x - sv||² using vDSP
            let len = min(n, sv.count)
            var diff = [Double](repeating: 0, count: len)
            for j in 0..<len { diff[j] = scaledFeatures[j] - sv[j] }
            var normSq: Double = 0
            vDSP_svesqD(diff, 1, &normSq, vDSP_Length(len))
            let k = exp(-gamma * normSq)
            decision += dualCoef[i] * k
        }

        return decision
    }
}
