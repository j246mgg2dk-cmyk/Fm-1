import SwiftUI

@main
struct MachinedrumApp: App {
    @StateObject private var machine = MachineController()

    var body: some Scene {
        WindowGroup {
            MachineView()
                .environmentObject(machine)
                .environmentObject(machine.panel)
                .preferredColorScheme(.dark)
        }
    }
}
