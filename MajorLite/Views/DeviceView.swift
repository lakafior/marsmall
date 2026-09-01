import SwiftUI

/// The main screen: a glass hero card with live state, then the settings we
/// were able to decode.
struct DeviceView: View {
    @Environment(DeviceStore.self) private var store
    @State private var findingMe = false

    var body: some View {
        List {
            Section { HeroCard() }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            controlsSection
            timersSection
            infoSection
        }
        .listStyle(.insetGrouped)
        .refreshable { await store.refreshAll() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Disconnect", systemImage: "xmark") { store.disconnect() }
                    .labelStyle(.iconOnly)
            }
        }
        .alert("Change not applied",
               isPresented: .constant(store.lastError != nil),
               presenting: store.lastError) { _ in
            Button("OK") { store.lastError = nil }
        } message: { message in
            Text(message)
        }
    }

    // MARK: - Controls

    @ViewBuilder
    private var controlsSection: some View {
        Section("Controls") {
            NavigationLink {
                MButtonView()
            } label: {
                LabeledContent {
                    Text(store.buttonAction?.title ?? "—")
                        .foregroundStyle(.secondary)
                } label: {
                    Label("M-Button", systemImage: "button.horizontal.top.press")
                }
            }

            NavigationLink {
                EqualiserView()
            } label: {
                LabeledContent {
                    Text(equaliserSummary).foregroundStyle(.secondary)
                } label: {
                    Label("Equaliser", systemImage: "slider.horizontal.3")
                }
            }

            Toggle(isOn: Binding(
                get: { store.interactionSounds ?? false },
                set: { on in Task { await store.setInteractionSounds(on) } }
            )) {
                Label("Interaction sounds", systemImage: "speaker.wave.2")
            }
            .disabled(store.interactionSounds == nil)

            Picker(selection: Binding(
                get: { store.batteryPreservation ?? .none },
                set: { level in Task { await store.setBatteryPreservation(level) } }
            )) {
                ForEach(MajorV.BatteryPreservation.allCases) { level in
                    Text(level.title).tag(level)
                }
            } label: {
                Label("Battery preservation", systemImage: "battery.75percent")
            }
            .disabled(store.batteryPreservation == nil)

            Button {
                Task {
                    findingMe.toggle()
                    await store.findMe(findingMe)
                }
            } label: {
                Label(findingMe ? "Stop sound" : "Find my headphones",
                      systemImage: findingMe ? "speaker.slash" : "bell.and.waves.left.and.right")
            }
            .disabled(!store.raceReady)

            if let level = store.batteryPreservation {
                Text(level.caption)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Timers

    @ViewBuilder
    private var timersSection: some View {
        if !store.autoOffTimers.isEmpty {
            Section {
                ForEach(store.autoOffTimers) { timer in
                    Picker(selection: Binding(
                        get: { timer.seconds },
                        set: { s in Task { await store.setAutoOffTimer(timer, seconds: s) } }
                    )) {
                        ForEach(MajorV.AutoOffTimer.choices, id: \.self) { s in
                            Text(MajorV.AutoOffTimer.format(s)).tag(s)
                        }
                    } label: {
                        Text(timer.title)
                    }
                }
            } header: {
                Text("Switch off automatically")
            } footer: {
                Text("Not every value is necessarily accepted by the firmware. If a choice does not stick, the previous one is restored.")
            }
        }
    }

    // MARK: - Information

    @ViewBuilder
    private var infoSection: some View {
        Section("Device") {
            row("Model", store.model)
            row("Firmware", store.firmware)
            row("Hardware", store.hardware)
            row("Manufacturer", store.manufacturer)
            row("Serial", store.serial)

            NavigationLink {
                DiagnosticsView()
            } label: {
                Label("Diagnostics", systemImage: "stethoscope")
            }

            NavigationLink {
                ExperimentsView()
            } label: {
                Label("Experiments", systemImage: "flask")
            }
        }
    }

    private var equaliserSummary: String {
        guard let slot = store.equaliserSlot else { return "—" }
        if slot == 1 { return "Slot 1 · Marshall" }
        return "Slot 2 · \(store.equaliserPreset?.title ?? "—")"
    }

    @ViewBuilder
    private func row(_ title: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            LabeledContent(title) {
                Text(value)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Hero

/// Battery, and whatever the headphones report as now playing.
private struct HeroCard: View {
    @Environment(DeviceStore.self) private var store

    var body: some View {
        GlassEffectContainer(spacing: 16) {
            VStack(spacing: 18) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: store.isCharging ? "battery.100percent.bolt" : batterySymbol)
                        .font(.title2)
                        .foregroundStyle(store.isCharging ? .green : batteryTint)
                        .symbolEffect(.pulse, isActive: store.isCharging)
                    Text(store.batteryPercent.map { "\($0)%" } ?? "—")
                        .font(.system(size: 44, weight: .semibold, design: .rounded))
                        .contentTransition(.numericText())
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(store.ble.deviceName ?? "Major V")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if store.isCharging {
                            Text("Charging")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                        if let v = store.volume {
                            Label("\(v)", systemImage: "speaker.wave.2.fill")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                if let title = store.nowPlaying[1], !title.isEmpty {
                    Divider().opacity(0.4)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.callout.weight(.medium))
                            .lineLimit(2)
                        if let subtitle = store.nowPlaying[2], !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(20)
            .glassEffect(.regular, in: .rect(cornerRadius: 26))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .animation(.smooth, value: store.batteryPercent)
    }

    private var batterySymbol: String {
        switch store.batteryPercent ?? 0 {
        case ..<15: "battery.25percent"
        case ..<50: "battery.50percent"
        case ..<85: "battery.75percent"
        default: "battery.100percent"
        }
    }

    private var batteryTint: Color {
        (store.batteryPercent ?? 100) < 15 ? .red : .green
    }
}
