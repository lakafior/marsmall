import SwiftUI

struct RootView: View {
    @Environment(DeviceStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Group {
                if store.isConnected {
                    DeviceView()
                } else {
                    ConnectView()
                }
            }
            .navigationTitle("Major V")
        }
        .task {
            if !store.isConnected { await store.connect() }
        }
        // Polling only makes sense while the app is on screen.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { store.stopPolling(); return }
            if store.isConnected {
                store.startPolling()
            } else {
                // Coming back to a dropped connection - pick it up again silently.
                Task { await store.connect() }
            }
        }
    }
}

/// Shown until the headphones are reachable.
private struct ConnectView: View {
    @Environment(DeviceStore.self) private var store

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            Image(systemName: "headphones")
                .font(.system(size: 68, weight: .light))
                .foregroundStyle(.secondary)
                .padding(36)
                .glassEffect(.regular, in: .circle)

            VStack(spacing: 8) {
                Text(statusTitle)
                    .font(.title2.weight(.semibold))
                Text(statusDetail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            if !isBusy {
                Button("Connect") {
                    Task { await store.connect() }
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            } else {
                ProgressView()
            }

            Spacer()
        }
    }

    private var isBusy: Bool {
        store.ble.state == .scanning || store.ble.state == .connecting
    }

    private var statusTitle: String {
        switch store.ble.state {
        case .scanning: "Looking for your headphones"
        case .connecting: "Connecting"
        case .unauthorised: "Bluetooth access needed"
        case .poweredOff: "Bluetooth is off"
        case .failed: "Not connected"
        default: "Not connected"
        }
    }

    private var statusDetail: String {
        switch store.ble.state {
        case .unauthorised:
            "Allow Bluetooth for this app in Settings › Privacy & Security › Bluetooth."
        case .poweredOff:
            "Turn Bluetooth on to continue."
        case .failed(let message):
            message
        default:
            "Your Major V must be switched on and paired with this iPhone in Settings › Bluetooth."
        }
    }
}
