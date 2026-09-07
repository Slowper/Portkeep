import SwiftUI

@main
struct PortsideApp: App {
    @State private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            DashboardView()
                .environment(state)
        } label: {
            MenuBarLabel(count: state.visiblePorts.count)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(state)
        }
    }
}

struct MenuBarLabel: View {
    let count: Int

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "network")
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .monospacedDigit()
            }
        }
    }
}
