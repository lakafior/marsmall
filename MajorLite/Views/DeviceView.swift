import SwiftUI

/// The main screen: a glass hero card with live state, then the settings we
/// were able to decode.
struct DeviceView: View {
    @Environment(DeviceStore.self) private var store
    @State private var findingMe = false

    var body: some View {
        List {
            Section { HeroCard() }
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

            if let level = store.batteryPreservation {
                Text(level.caption)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

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

            if !store.raceReady {
                Text("Battery and Find my headphones need the Airoha channel, which is not open on this connection. Pull down to refresh, or reconnect.")
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

/// Battery, volume and whatever the headphones report as now playing.
private struct HeroCard: View {
    @Environment(DeviceStore.self) private var store

    var body: some View {
        GlassEffectContainer(spacing: 14) {
            VStack(alignment: .leading, spacing: 16) {
                header
                if hasTrack { nowPlaying }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 22))
        }
        .animation(.smooth, value: store.batteryPercent)
        .animation(.smooth, value: store.nowPlaying[1])
    }

    // MARK: - Battery and volume
    //
    // Nazwa urzadzenia i informacja o ladowaniu maja wlasny wiersz. Gdy siedzialy
    // w jednej linii z procentem, dluzsze napisy ("MAJOR V [LE]", "Charging
    // wirelessly") sciskaly go i lamaly na dwie linie.

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(store.ble.deviceName ?? "Major V")
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                if let note = store.batteryStatus?.summary {
                    Text(note)
                        .foregroundStyle(store.isCharging ? .green : .orange)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)

            HStack(alignment: .firstTextBaseline, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: store.isCharging ? "battery.100percent.bolt" : batterySymbol)
                        .font(.title3)
                        .foregroundStyle(store.isCharging ? .green : batteryTint)
                        .symbolEffect(.pulse, isActive: store.isCharging)
                    Text(store.batteryPercent.map { "\($0)%" } ?? "—")
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .fixedSize()
                }

                if let v = store.volume {
                    Divider().frame(height: 22)
                    // Jawny HStack zamiast Label: w wierszu listy Label potrafi
                    // przejac styl ze srodowiska i zwinac sie do samej ikony.
                    HStack(spacing: 5) {
                        Image(systemName: "speaker.wave.2.fill")
                        Text(store.volumeLimit.map { "\(v)/\($0)" } ?? "\(v)")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                }

                if let src = store.audioSource {
                    Divider().frame(height: 22)
                    HStack(spacing: 5) {
                        Image(systemName: src.symbol)
                        Text(src.title)
                    }
                    .font(.subheadline)
                    .foregroundStyle(src == .bluetooth ? .secondary : Color.accentColor)
                    .lineLimit(1)
                    .fixedSize()
                }

                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Now playing

    private var hasTrack: Bool { !(store.nowPlaying[1] ?? "").isEmpty }

    private var nowPlaying: some View {
        HStack(spacing: 12) {
            Image(systemName: (store.isPlaying ?? false) ? "waveform" : "pause.fill")
                .font(.title3)
                .symbolEffect(.variableColor.iterative, isActive: store.isPlaying ?? false)
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Color.accentColor.gradient, in: .rect(cornerRadius: 11))

            VStack(alignment: .leading, spacing: 2) {
                Text(store.nowPlaying[1] ?? "")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                if let artist = store.nowPlaying[2], !artist.isEmpty {
                    Text(artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let extra = store.nowPlaying[3], !extra.isEmpty {
                    Text(extra)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
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
