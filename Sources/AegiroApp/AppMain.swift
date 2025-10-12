
import SwiftUI
import AegiroCore

@main
struct AegiroAppMain: App {
    @State private var showFirstRun = true
    var body: some Scene {
        WindowGroup {
            if showFirstRun {
                FirstRunView(onDone: { showFirstRun = false })
            } else {
                MainView()
            }
        }
        .windowStyle(.hiddenTitleBar)
        MenuBarExtra("Aegiro", systemImage: "lock.shield") {
            MenuBarView()
        }
    }
}
