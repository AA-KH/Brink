import SwiftUI
import CoreMotion
import Combine

// MARK: - MotionViewModel
//
// Central ObservableObject owning the complete four-stage Brink pipeline.
//
// Stage 1 — Ambient monitor (15 Hz, always on)
//           SensorPipeline → ambientWindow → RollingBaselineAccumulator
//
// Stage 2 — Mahalanobis anomaly gate (15 Hz)
//           BrinkMLEngine.mahalanobisDistance on 6 anomaly features.
//           Exceeding threshold → ramp to 60 Hz, open active window.
//           Far more accurate than z-score: handles feature correlations.
//
// Stage 3 — Full inference (60 Hz, time-limited 3 s)
//           BrinkMLEngine.infer: RobustScaler → GBT (CoreML) →
//           isotonic calibration → one-class SVM veto
//
// Stage 4 — CUSUM detector (inside BrinkMLEngine.infer)
//           Mathematically optimal sequential change-point detection.
//           Alert fires only when CUSUM accumulates sufficient evidence
//           AND the veto SVM does not reject the window.
//
// All sensor and ML work runs on SensorPipeline.pipelineQueue (serial).
// State updates hop to @MainActor before touching @Published properties.

@MainActor
final class MotionViewModel: ObservableObject {

    // MARK: - Published State

    @Published var riskLevel: RiskLevel = .safe
    @Published var motionReading: MotionReading = .idle
    @Published var riskScore: Double = 0.0
    @Published var isMonitoring: Bool = false
    @Published var showAlert: Bool = false
    @Published var activeAlertEvent: AlertEvent? = nil
    @Published var alertHistory: [AlertEvent] = []
    @Published var samplingMode: SamplingMode = .ambient

    // ML engine readiness — shown in settings / debug UI
    @Published var mlEngineReady: Bool = false
    @Published var mlEngineStatus: String = "Loading…"

    // MARK: - Settings (AppStorage)

    @AppStorage("sensitivityLevel") var sensitivityRaw: String = SensitivityLevel.balanced.rawValue
    @AppStorage("alertStyleRaw")    var alertStyleRaw:  String = AlertStyle.vibrationOnly.rawValue
    @AppStorage("surfaceModeRaw")   var surfaceModeRaw: String = SurfaceMode.auto.rawValue
    @AppStorage("quietHoursData")   private var quietHoursData: Data = (try? JSONEncoder().encode(QuietHours.default)) ?? Data()
    @AppStorage("historyData")      private var historyData: Data = Data()

    var sensitivity: SensitivityLevel {
        get { SensitivityLevel(rawValue: sensitivityRaw) ?? .balanced }
        set {
            sensitivityRaw = newValue.rawValue
            // Reconfigure CUSUM on pipeline queue when sensitivity changes
            pipeline.pipelineQueue.async { [weak self] in
                guard let self else { return }
                self.mlEngine.configureCUSUM(sensitivity: newValue)
            }
        }
    }
    var alertStyle: AlertStyle {
        get { AlertStyle(rawValue: alertStyleRaw) ?? .vibrationOnly }
        set { alertStyleRaw = newValue.rawValue }
    }
    var surfaceMode: SurfaceMode {
        get { SurfaceMode(rawValue: surfaceModeRaw) ?? .auto }
        set { surfaceModeRaw = newValue.rawValue }
    }
    var quietHours: QuietHours {
        get { (try? JSONDecoder().decode(QuietHours.self, from: quietHoursData)) ?? .default }
        set { quietHoursData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    // MARK: - Core Objects

    private let pipeline  = SensorPipeline()
    private let mlEngine  = BrinkMLEngine()
    
    weak var dataCollectionManager: DataCollectionManager?

    // MARK: - Window Configuration

    private enum WindowConfig {
        static let ambientSampleRate:     Double = 15.0
        static let activeSampleRate:      Double = 60.0
        static let baselineWindowSamples: Int    = 300   // 20 s @ 15 Hz
        static let extractionSamples:     Int    = 30    // 0.5 s @ 60 Hz
        static let anomalyFeatureCount:   Int    = 6
    }

    // MARK: - Baseline Accumulator (anomaly gate)

    private let baselineAccumulator = RollingBaselineAccumulator(
        featureCount: WindowConfig.anomalyFeatureCount,
        windowSize:   WindowConfig.baselineWindowSamples
    )

    // MARK: - Window Buffers (accessed only on pipelineQueue)

    private var ambientWindow = WindowBuffers(
        capacity:   30,
        sampleRate: WindowConfig.ambientSampleRate
    )

    private var activeWindow = WindowBuffers(
        capacity:   WindowConfig.extractionSamples,
        sampleRate: WindowConfig.activeSampleRate
    )

    // MARK: - Simulation Fallback

    private var simulationTimer: Timer?
    private var simulationPhase: Double = 0.0

    // MARK: - Init

    init() {
        loadHistory()
        configurePipeline()
        checkMLEngineStatus()
        startMonitoring()
    }

    deinit {
        pipeline.stop()
        simulationTimer?.invalidate()
    }

    // MARK: - ML Engine Status Check

    private func checkMLEngineStatus() {
        // BrinkMLEngine loads synchronously in init.
        // Check bundle for the key files to report status accurately.
        let hasGBT = Bundle.main.url(forResource: "BrinkClassifier",
                                      withExtension: "mlpackage") != nil
                  || Bundle.main.url(forResource: "BrinkClassifier",
                                      withExtension: "mlmodelc") != nil
        let hasParams = Bundle.main.url(forResource: "brink_runtime_params",
                                         withExtension: "json") != nil

        if hasGBT && hasParams {
            mlEngineReady  = true
            mlEngineStatus = "ML Engine active"
        } else if hasParams && !hasGBT {
            mlEngineReady  = true
            mlEngineStatus = "Heuristic mode (no GBT model)"
        } else {
            mlEngineReady  = false
            mlEngineStatus = "ML Engine not loaded — add .mlpackage and JSON to bundle"
        }

        // Configure CUSUM with current sensitivity
        pipeline.pipelineQueue.async { [weak self] in
            guard let self else { return }
            self.mlEngine.configureCUSUM(sensitivity: self.sensitivity)
        }
    }

    // MARK: - Pipeline Configuration

    private func configurePipeline() {
        pipeline.onModeChange = { [weak self] mode in
            guard let self else { return }
            Task { @MainActor in
                withAnimation(BrinkAnimation.standard) { self.samplingMode = mode }
            }
        }

        pipeline.onSample = { [weak self] sample in
            guard let self else { return }
            // Runs on pipelineQueue — all ML state access is safe here
            self.processSample(sample)
        }
    }

    // MARK: - Lifecycle

    func startMonitoring() {
        isMonitoring = true
        if CMMotionManager().isDeviceMotionAvailable {
            pipeline.start()
        } else {
            startSimulation()
        }
    }

    func stopMonitoring() {
        isMonitoring = false
        pipeline.stop()
        simulationTimer?.invalidate()
        simulationTimer = nil
    }

    // MARK: - Stage 1 + 2: Ambient Processing (pipelineQueue)

    private func processSample(_ sample: SensorSample) {
        dataCollectionManager?.append(sample: sample, featureVector: nil)

        // Gate: suppress all detection in high-motion activities
        guard !sample.activity.suppressesAlerts else {
            if case .active = pipeline.mode { pipeline.dropToAmbient() }
            updateUIReading(sample)
            return
        }

        // Accumulate ambient window
        ambientWindow.append(sample)

        // Extract 6 anomaly features
        if let anomalyFeatures = FeatureExtractor.extractAnomalyFeatures(from: ambientWindow) {

            // Feed baseline accumulator (builds the Mahalanobis reference)
            baselineAccumulator.append(anomalyFeatures)

            // Stage 2: Mahalanobis gate (only while in ambient mode)
            if case .ambient = pipeline.mode,
               baselineAccumulator.isReady {

                let distance = mlEngine.mahalanobisDistance(anomalyFeatures: anomalyFeatures)

                if distance >= mlEngine.mahalanobisThreshold {
                    // Anomaly detected — ramp to 60 Hz
                    pipeline.activateHighFrequency()
                    activeWindow.reset()
                    mlEngine.resetCUSUM()
                }
            }
        }

        // Stage 3: Active-mode feature extraction and inference
        if case .active = pipeline.mode {
            runActiveInference(sample: sample)
        }

        updateUIReading(sample)
    }

    // MARK: - Stage 3 + 4: Active Inference (pipelineQueue)

    private func runActiveInference(sample: SensorSample) {
        activeWindow.append(sample)

        // Only run inference when we have a full window
        guard let featureVector = FeatureExtractor.extract(from: activeWindow) else { return }

        // Full inference: GBT → isotonic calibration → veto → CUSUM
        let result = mlEngine.infer(featureVector: featureVector, sensitivity: sensitivity)

        // Update continuous UI score on main actor
        let displayScore = result.displayScore
        let newLevel     = riskLevelFor(score: displayScore)

        Task { @MainActor in
            self.riskScore = displayScore
            if newLevel != self.riskLevel {
                withAnimation(BrinkAnimation.stateTransition) { self.riskLevel = newLevel }
            }
        }

        // Alert gate
        if result.shouldAlert {
            Task { @MainActor in
                guard !self.isInQuietHours(), !self.showAlert else { return }
                self.triggerAlert(result: result, sample: sample)
            }
            // Drop back to ambient — the event has been detected
            pipeline.dropToAmbient()
        }

        // Roll window forward by half its length (50% overlap)
        // so the next extraction shares context with the current one
        rollActiveWindow()
    }

    // MARK: - Window Roll (50% overlap)
    //
    // Instead of fully resetting after each extraction, copy the second
    // half of the current window into a fresh buffer.  This means every
    // feature vector is computed on data that overlaps 50% with the
    // previous one — dramatically reducing latency on fast events.

    private func rollActiveWindow() {
        let half     = activeWindow.capacity / 2
        let rollback = activeWindow.capacity - half

        // Snapshot the second half of current window into temp arrays
        var newAcc   = TripleBuffer(capacity: activeWindow.capacity)
        var newRot   = TripleBuffer(capacity: activeWindow.capacity)
        var newPitch = CircularBuffer(capacity: activeWindow.capacity)
        var newRoll  = CircularBuffer(capacity: activeWindow.capacity)
        var newPres  = CircularBuffer(capacity: activeWindow.capacity)
        var newAlt   = CircularBuffer(capacity: activeWindow.capacity)

        for i in half..<activeWindow.capacity {
            newAcc.append(
                x: activeWindow.acc.x[i],
                y: activeWindow.acc.y[i],
                z: activeWindow.acc.z[i]
            )
            newRot.append(
                x: activeWindow.rot.x[i],
                y: activeWindow.rot.y[i],
                z: activeWindow.rot.z[i]
            )
            newPitch.append(activeWindow.pitch[i])
            newRoll.append(activeWindow.roll[i])
            newPres.append(activeWindow.pressure(at: i))
            newAlt.append(activeWindow.altitude(at: i))
        }

        activeWindow = WindowBuffers(
            capacity:   activeWindow.capacity,
            sampleRate: activeWindow.sampleRate
        )
        activeWindow.acc             = newAcc
        activeWindow.rot             = newRot
        activeWindow.pitch           = newPitch
        activeWindow.roll            = newRoll
        activeWindow.pressureHistory = newPres
        activeWindow.altitudeHistory = newAlt

        _ = rollback  // suppress unused warning
    }

    // MARK: - Risk Level

    private func riskLevelFor(score: Double) -> RiskLevel {
        switch score {
        case 0.0..<0.25: return .safe
        case 0.25..<0.55: return .low
        case 0.55..<0.80: return .medium
        default:          return .high
        }
    }

    // MARK: - UI Reading Update

    private func updateUIReading(_ sample: SensorSample) {
        let accNorm = min(sample.accMagnitude / 2.0, 1.0)
        let rotNorm = min(sample.rotMagnitude / 6.0, 1.0)
        let stab    = max(0.0, 1.0 - (accNorm * 0.6 + rotNorm * 0.4))

        let reading = MotionReading(
            accelerationMagnitude: sample.accMagnitude,
            rotationMagnitude:     sample.rotMagnitude,
            pitch:                 sample.pitch,
            roll:                  sample.roll,
            stabilityScore:        stab
        )
        Task { @MainActor in self.motionReading = reading }
    }

    // MARK: - Alert Lifecycle

    private func triggerAlert(result: InferenceResult, sample: SensorSample) {
        let context = alertContext(result: result, sample: sample)
        let event   = AlertEvent(
            date:      Date(),
            riskLevel: riskLevel.rawValue,
            context:   context,
            dismissed: false
        )
        activeAlertEvent = event
        withAnimation(BrinkAnimation.alertSlide) { showAlert = true }
        fireHaptic()
    }

    func dismissAlert() {
        guard var event = activeAlertEvent else { return }
        event.dismissed = true
        alertHistory.insert(event, at: 0)
        if alertHistory.count > 50 { alertHistory = Array(alertHistory.prefix(50)) }
        saveHistory()
        withAnimation(BrinkAnimation.alertSlide) { showAlert = false }
        activeAlertEvent = nil
        // Reset CUSUM on the pipeline queue
        pipeline.pipelineQueue.async { [weak self] in
            self?.mlEngine.resetCUSUM()
        }
    }

    func clearHistory() {
        alertHistory = []
        saveHistory()
    }

    // MARK: - Demo Simulation Triggers

    func simulateRiskEvent(_ level: RiskLevel) {
        let targetScore: Double
        switch level {
        case .safe:   targetScore = 0.10
        case .low:    targetScore = 0.38
        case .medium: targetScore = 0.67
        case .high:   targetScore = 0.91
        }
        riskScore = targetScore
        withAnimation(BrinkAnimation.stateTransition) { riskLevel = level }

        if level >= .high {
            let event = AlertEvent(
                date:      Date(),
                riskLevel: level.rawValue,
                context:   demoPrecannedContext(level: level),
                dismissed: false
            )
            activeAlertEvent = event
            withAnimation(BrinkAnimation.alertSlide) { showAlert = true }
            fireHaptic()
        }
    }

    // MARK: - Simulation Fallback (Simulator only)

    private func startSimulation() {
        simulationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.tickSimulation() }
        }
    }

    private func tickSimulation() {
        simulationPhase += 0.04
        let baseAcc   = 0.02 + 0.01 * sin(simulationPhase * 1.3)
        let baseRot   = 0.05 + 0.03 * sin(simulationPhase * 0.7)
        let basePitch = 0.05 * sin(simulationPhase * 0.4)
        let baseRoll  = 0.03 * cos(simulationPhase * 0.5)
        let accNorm   = min(baseAcc / 2.0, 1.0)
        let rotNorm   = min(baseRot / 6.0, 1.0)

        motionReading = MotionReading(
            accelerationMagnitude: baseAcc,
            rotationMagnitude:     baseRot,
            pitch:                 basePitch,
            roll:                  baseRoll,
            stabilityScore:        max(0, 1 - (accNorm * 0.6 + rotNorm * 0.4))
        )
        let simScore = min(baseAcc * 2.5 + baseRot * 0.4, 1.0)
        riskScore    = simScore
        let newLevel = riskLevelFor(score: simScore)
        if newLevel != riskLevel {
            withAnimation(BrinkAnimation.stateTransition) { riskLevel = newLevel }
        }
    }

    // MARK: - Helpers

    private func isInQuietHours() -> Bool {
        guard quietHours.isEnabled else { return false }
        let cal        = Calendar.current
        let now        = Date()
        let nowTotal   = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
        let startTotal = quietHours.startHour * 60 + quietHours.startMinute
        let endTotal   = quietHours.endHour   * 60 + quietHours.endMinute
        return startTotal <= endTotal
            ? nowTotal >= startTotal && nowTotal < endTotal
            : nowTotal >= startTotal || nowTotal < endTotal
    }

    private func fireHaptic() {
        switch alertStyle {
        case .vibrationOnly, .soundAndVibration:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .visualOnly, .silent:
            break
        }
    }

    private func alertContext(result: InferenceResult, sample: SensorSample) -> String {
        let tiltAngle = sqrt(sample.pitch * sample.pitch + sample.roll * sample.roll)
        let isDrifting = sample.rotMagnitude > 1.5
        switch riskLevel {
        case .safe:   return "All clear"
        case .low:    return isDrifting ? "Slight rotation instability" : "Minor instability"
        case .medium:
            if tiltAngle > 0.6  { return "Edge tilt warning" }
            if isDrifting       { return "Surface instability detected" }
            return "Unstable position detected"
        case .high:
            if tiltAngle > 0.9         { return "High tilt — fall risk" }
            if sample.rotMagnitude > 3 { return "Grip instability detected" }
            return "Fall risk — act now"
        }
    }

    private func demoPrecannedContext(level: RiskLevel) -> String {
        let contexts: [RiskLevel: [String]] = [
            .low:    ["Minor motion detected", "Slight instability"],
            .medium: ["Unstable position detected", "Edge tilt warning"],
            .high:   ["Fall risk — high tilt detected", "Grip instability detected",
                      "Edge fall risk — act now"],
        ]
        return contexts[level]?.randomElement() ?? "Risk detected"
    }

    private func saveHistory() {
        historyData = (try? JSONEncoder().encode(alertHistory)) ?? Data()
    }

    private func loadHistory() {
        alertHistory = (try? JSONDecoder().decode([AlertEvent].self, from: historyData)) ?? []
    }
}
