import Foundation
import CoreMotion

// MARK: - SamplingMode
//
// The pipeline runs in one of two modes at all times to balance battery
// life against detection precision.
//
//  .ambient — 15 Hz.  Always on.  Maintains the rolling baseline and feeds
//             the lightweight anomaly gate.  Battery cost: negligible.
//
//  .active  — 60 Hz.  Triggered by the anomaly gate.  Feeds the full
//             feature extractor and ML classifier.  Auto-expires after
//             Config.activeWindowDuration seconds if not re-triggered.

enum SamplingMode: Equatable {
    case ambient
    case active(triggeredAt: Date)

    var isActive: Bool {
        if case .active = self { return true }
        return false
    }
}

// MARK: - DeviceActivity
//
// Normalised activity classification derived from CMMotionActivityManager.
// Stored on SensorSample so downstream logic can gate alerts appropriately.

enum DeviceActivity: String, Codable, Equatable {
    case stationary
    case walking
    case running
    case cycling
    case automotive
    case unknown

    /// Initialise from a raw CMMotionActivity, applying Apple's documented
    /// confidence-ordered priority (automotive beats cycling beats running, etc.).
    init(_ cmActivity: CMMotionActivity) {
        if      cmActivity.automotive { self = .automotive }
        else if cmActivity.cycling    { self = .cycling    }
        else if cmActivity.running    { self = .running    }
        else if cmActivity.walking    { self = .walking    }
        else if cmActivity.stationary { self = .stationary }
        else                          { self = .unknown    }
    }

    /// True when background motion is so high that the alert thresholds
    /// must be elevated dramatically to suppress environmental false positives.
    var suppressesAlerts: Bool {
        switch self {
        case .running, .cycling, .automotive: return true
        default:                              return false
        }
    }
}

// MARK: - SensorSample
//
// One fully-resolved snapshot delivered per pipeline tick.  Merges Device
// Motion (user acceleration, rotation rate, attitude, gravity), Altimeter
// (pressure, relative altitude), and Activity into a single immutable value.
//
// All fields are in SI units unless documented otherwise.

struct SensorSample {

    // Motion timestamp — seconds elapsed since device boot (monotonic).
    let timestamp: TimeInterval
    let date: Date

    // User acceleration (gravity removed), in g-units (1 g ≈ 9.81 m/s²).
    let accX: Double
    let accY: Double
    let accZ: Double

    // Rotation rate around each body axis, rad/s.
    let rotX: Double
    let rotY: Double
    let rotZ: Double

    // Euler attitude angles, radians.
    let pitch: Double   // nose up/down
    let roll: Double    // left/right tilt
    let yaw: Double     // rotation around vertical axis

    // Unit gravity vector (points toward ground).
    let gravX: Double
    let gravY: Double
    let gravZ: Double

    // Atmospheric pressure in kPa (standard atmosphere ≈ 101.325 kPa).
    let pressure: Double

    // Altitude change in metres relative to when the altimeter session started.
    let relativeAltitude: Double

    // CMMotionActivityManager classification at sample time.
    let activity: DeviceActivity

    // Derived — computed once so callers never pay sqrt twice.
    let accMagnitude: Double    // √(accX² + accY² + accZ²)
    let rotMagnitude: Double    // √(rotX² + rotY² + rotZ²)

    init(motion: CMDeviceMotion,
         pressure: Double,
         relativeAltitude: Double,
         activity: DeviceActivity) {

        self.timestamp        = motion.timestamp
        self.date             = Date()

        self.accX             = motion.userAcceleration.x
        self.accY             = motion.userAcceleration.y
        self.accZ             = motion.userAcceleration.z

        self.rotX             = motion.rotationRate.x
        self.rotY             = motion.rotationRate.y
        self.rotZ             = motion.rotationRate.z

        self.pitch            = motion.attitude.pitch
        self.roll             = motion.attitude.roll
        self.yaw              = motion.attitude.yaw

        self.gravX            = motion.gravity.x
        self.gravY            = motion.gravity.y
        self.gravZ            = motion.gravity.z

        self.pressure         = pressure
        self.relativeAltitude = relativeAltitude
        self.activity         = activity

        self.accMagnitude     = sqrt(
            motion.userAcceleration.x * motion.userAcceleration.x +
            motion.userAcceleration.y * motion.userAcceleration.y +
            motion.userAcceleration.z * motion.userAcceleration.z
        )
        self.rotMagnitude     = sqrt(
            motion.rotationRate.x * motion.rotationRate.x +
            motion.rotationRate.y * motion.rotationRate.y +
            motion.rotationRate.z * motion.rotationRate.z
        )
    }
}

// MARK: - SensorPipeline
//
// Owns all CoreMotion manager instances and the sampling-mode state machine.
// Samples are delivered to `onSample` on `pipelineQueue` — a private serial
// DispatchQueue.  Callers MUST dispatch to the main actor themselves before
// touching any @Published state.
//
// Typical lifecycle:
//   pipeline.onSample = { [weak self] sample in
//       self?.pipelineQueue.async { ... }   // already on pipelineQueue
//       Task { @MainActor in ... }          // hop to UI
//   }
//   pipeline.start()
//   ...
//   pipeline.stop()

final class SensorPipeline {

    // MARK: - Configuration

    private enum Config {
        // Sensor update frequencies
        static let ambientHz:   Double       = 15.0
        static let activeHz:    Double       = 60.0

        // How long to stay in active mode after the last gate trigger.
        // If the anomaly resolves within this window we drop back without alerting.
        static let activeWindowDuration: TimeInterval = 3.0

        // We use xArbitraryZVertical so that the Z-axis always points up
        // regardless of portrait / landscape orientation, giving a stable
        // gravity vector for tilt computation.
        static let motionFrame: CMAttitudeReferenceFrame = .xArbitraryZVertical
    }

    // MARK: - Public Interface

    /// Invoked on `pipelineQueue` for every sensor sample.
    var onSample: ((SensorSample) -> Void)?

    /// Invoked on `pipelineQueue` whenever the SamplingMode changes.
    var onModeChange: ((SamplingMode) -> Void)?

    /// The current sampling mode. Read from any thread; written only on
    /// `pipelineQueue`.
    private(set) var mode: SamplingMode = .ambient

    private(set) var isRunning: Bool = false

    // MARK: - CoreMotion Instances

    private let motionManager   = CMMotionManager()
    private let activityManager = CMMotionActivityManager()
    private let altimeter       = CMAltimeter()

    // MARK: - Dedicated Pipeline Queue
    //
    // Serial queue — all state mutation, all sensor callbacks, and all calls
    // to onSample happen here.  No locks needed.

    let pipelineQueue = DispatchQueue(
        label: "com.brink.sensorpipeline",
        qos: .userInteractive
    )

    // MARK: - Mutable Pipeline State (access only on pipelineQueue)

    private var latestPressure:       Double = 101.325
    private var latestAltitude:       Double = 0.0
    private var latestActivity:       DeviceActivity = .unknown
    private var activeWindowDeadline: Date? = nil

    // MARK: - Lifecycle

    func start() {
        pipelineQueue.async { [weak self] in
            guard let self, !self.isRunning else { return }
            self.isRunning = true
            self.startActivityManager()
            self.startAltimeter()
            self.applyMotionUpdateRate(Config.ambientHz)
            self.transitionMode(to: .ambient)
        }
    }

    func stop() {
        pipelineQueue.async { [weak self] in
            guard let self, self.isRunning else { return }
            self.isRunning = false
            self.motionManager.stopDeviceMotionUpdates()
            self.activityManager.stopActivityUpdates()
            self.altimeter.stopRelativeAltitudeUpdates()
            self.activeWindowDeadline = nil
            self.transitionMode(to: .ambient)
        }
    }

    // MARK: - Mode Control (call from pipelineQueue or any queue — serialised internally)

    /// Ramp to 60 Hz.  Called by the anomaly gate when a suspicious deviation
    /// is detected.  If already active, the window is extended instead.
    func activateHighFrequency() {
        pipelineQueue.async { [weak self] in
            guard let self, self.isRunning else { return }
            let newDeadline = Date().addingTimeInterval(Config.activeWindowDuration)

            if case .active = self.mode {
                // Already active — just push out the deadline.
                self.activeWindowDeadline = newDeadline
                return
            }

            self.activeWindowDeadline = newDeadline
            self.transitionMode(to: .active(triggeredAt: Date()))
            self.applyMotionUpdateRate(Config.activeHz)

            // Schedule automatic fallback to ambient.
            self.pipelineQueue.asyncAfter(
                deadline: .now() + Config.activeWindowDuration
            ) { [weak self] in
                guard let self else { return }
                if let deadline = self.activeWindowDeadline, Date() >= deadline {
                    self.dropToAmbient()
                }
            }
        }
    }

    /// Return to 15 Hz immediately. Safe to call redundantly.
    func dropToAmbient() {
        // Must already be on pipelineQueue when called from the internal
        // asyncAfter block, but we may also be called from outside.
        let work = { [weak self] in
            guard let self, case .active = self.mode else { return }
            self.activeWindowDeadline = nil
            self.transitionMode(to: .ambient)
            self.applyMotionUpdateRate(Config.ambientHz)
        }
        if DispatchQueue.getSpecific(key: pipelineQueueKey) != nil {
            work()
        } else {
            pipelineQueue.async(execute: work)
        }
    }

    // MARK: - Private: Motion

    private func applyMotionUpdateRate(_ hz: Double) {
        guard motionManager.isDeviceMotionAvailable else { return }

        // Must stop before changing the interval; restarting is cheap.
        motionManager.stopDeviceMotionUpdates()
        motionManager.deviceMotionUpdateInterval = 1.0 / hz

        // CoreMotion delivers on a private OperationQueue thread.
        // We immediately re-dispatch onto our own serial queue so all
        // state access stays serialised without any locks.
        let callbackQueue = OperationQueue()
        callbackQueue.maxConcurrentOperationCount = 1
        callbackQueue.underlyingQueue = pipelineQueue

        motionManager.startDeviceMotionUpdates(
            using: Config.motionFrame,
            to: callbackQueue
        ) { [weak self] motion, error in
            guard let self, let motion, error == nil else { return }
            // Already on pipelineQueue via callbackQueue.underlyingQueue
            self.handleMotionUpdate(motion)
        }
    }

    private func handleMotionUpdate(_ motion: CMDeviceMotion) {
        // Safety: enforce active window expiry in case the async timer hasn't
        // fired yet.
        if case .active = mode,
           let deadline = activeWindowDeadline,
           Date() > deadline {
            dropToAmbient()
        }

        let sample = SensorSample(
            motion:           motion,
            pressure:         latestPressure,
            relativeAltitude: latestAltitude,
            activity:         latestActivity
        )

        onSample?(sample)
    }

    // MARK: - Private: Activity

    private func startActivityManager() {
        guard CMMotionActivityManager.isActivityAvailable() else { return }
        let callbackQueue = OperationQueue()
        callbackQueue.underlyingQueue = pipelineQueue

        activityManager.startActivityUpdates(to: callbackQueue) { [weak self] activity in
            guard let self, let activity else { return }
            // Already on pipelineQueue
            self.latestActivity = DeviceActivity(activity)
        }
    }

    // MARK: - Private: Altimeter

    private func startAltimeter() {
        guard CMAltimeter.isRelativeAltitudeAvailable() else { return }
        let callbackQueue = OperationQueue()
        callbackQueue.underlyingQueue = pipelineQueue

        altimeter.startRelativeAltitudeUpdates(to: callbackQueue) { [weak self] data, error in
            guard let self, let data, error == nil else { return }
            // Already on pipelineQueue
            self.latestPressure = data.pressure.doubleValue
            self.latestAltitude = data.relativeAltitude.doubleValue
        }
    }

    // MARK: - Private: Mode Transition

    private func transitionMode(to newMode: SamplingMode) {
        guard newMode != mode else { return }
        mode = newMode
        onModeChange?(newMode)
    }

    // MARK: - Queue Identity Key (for dropToAmbient re-entrancy check)

    private let pipelineQueueKey = DispatchSpecificKey<Void>()

    private func setupQueueKey() {
        pipelineQueue.setSpecific(key: pipelineQueueKey, value: ())
    }

    init() { setupQueueKey() }
}
