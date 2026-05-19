import SwiftUI

@main
struct BrinkApp: App {
    @StateObject private var viewModel = MotionViewModel()
    @StateObject private var dataCollectionManager = DataCollectionManager()

    @AppStorage("hasCompletedCalibration")
    private var hasCompletedCalibration = false

    var body: some Scene {
        WindowGroup {
            Group {
                if hasCompletedCalibration {
                    HomeView()
                } else {
                    CalibrationView(hasCompletedCalibration: $hasCompletedCalibration)
                }
            }
            .environmentObject(viewModel)
            .environmentObject(dataCollectionManager)
            .preferredColorScheme(.dark)
            .onAppear {
                viewModel.dataCollectionManager = dataCollectionManager
            }
        }
    }
}
