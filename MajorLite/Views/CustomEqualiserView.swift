import SwiftUI

/// Five sliders driving the parametric EQ.
///
/// Still an experiment. The band command is fully decoded and byte-identical to
/// what the official app sends, but on its own it changed nothing — the official
/// app also sends a 441-byte block of computed coefficients that is not decoded.
///
/// What was missed the first time: the headphones must actually be playing the
/// group these bands live in. The official app ends every edit with "PEQ group = 6",
/// and that group is what the Custom preset selects. So this screen now puts slot 2
/// on Custom, makes it active, and asks for group 6 explicitly.
///
/// Nothing here is written to permanent memory. Switch the headphones off and
/// whatever the official app last stored comes back.
struct CustomEqualiserView: View {
    @Environment(DeviceStore.self) private var store
    @State private var busy = false
    @State private var prepared = false
    @State private var applyTask: Task<Void, Never>?

    var body: some View {
        @Bindable var store = store

        List {
            Section {
                Button {
                    Task {
                        busy = true
                        await store.prepareForCustomEqualiser()
                        await store.applyCustomEqualiser()
                        prepared = true
                        busy = false
                    }
                } label: {
                    Label(prepared ? "Ready — move a slider" : "Switch to Custom and start",
                          systemImage: prepared ? "checkmark.circle" : "play.circle")
                }
                .disabled(busy || prepared)
            } footer: {
                Text("Puts slot 2 on Custom, makes it the active slot, then sends the bands. Without this the headphones play a different EQ group and nothing you do here can be heard.")
            }

            Section {
                ForEach(Array(MajorV.equaliserBands.enumerated()), id: \.offset) { index, band in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(MajorV.bandTitle(band.frequency))
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Text(store.customGains[index] == 0 ? "0.0 dB"
                                 : String(format: "%+.1f dB", store.customGains[index]))
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(store.customGains[index] == 0
                                                 ? .secondary : Color.accentColor)
                        }
                        Slider(value: $store.customGains[index],
                               in: MajorV.equaliserGainRange, step: 0.5)
                            .onChange(of: store.customGains[index]) { _, _ in scheduleApply() }
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Bands")
            } footer: {
                Text("Range ±6 dB, the same the official app allows.")
            }

            Section {
                Button("Flat", systemImage: "arrow.counterclockwise") {
                    Task {
                        busy = true
                        await store.resetCustomEqualiser()
                        busy = false
                    }
                }
                .disabled(busy || store.customGains.allSatisfy { $0 == 0 })
            } footer: {
                Text("""
                If you still hear no difference, the coefficient block really is \
                required and this is as far as it goes — see NOTES.md.

                To undo everything: switch the headphones off and on, or pick any \
                other preset on the Equaliser screen.
                """)
            }
        }
        .navigationTitle("Custom EQ")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(!store.raceReady)
        .overlay {
            if busy { ProgressView().controlSize(.large) }
            if !store.raceReady {
                ContentUnavailableView("Airoha channel not open",
                                       systemImage: "antenna.radiowaves.left.and.right.slash",
                                       description: Text("Reconnect, or reopen the channel from Experiments."))
            }
        }
    }

    /// Sliders emit a stream of values; collapse them so the headphones get one
    /// command per gesture rather than fifty.
    private func scheduleApply() {
        applyTask?.cancel()
        applyTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await store.applyCustomEqualiser()
        }
    }
}
