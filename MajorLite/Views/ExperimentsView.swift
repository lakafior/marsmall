import SwiftUI

/// Things the protocol appears to support but that have not been proven on this
/// hardware. Kept apart from the settings screen on purpose: the settings there
/// are confirmed, everything here is a question.
struct ExperimentsView: View {
    @Environment(DeviceStore.self) private var store

    @State private var probe: [String] = []
    @State private var probing = false

    var body: some View {
        List {
            capabilitiesSection
        }
        .navigationTitle("Experiments")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Capability probe

    @ViewBuilder
    private var capabilitiesSection: some View {
        Section {
            Text("""
            Asks the chip which state modules it implements. Read commands only — \
            nothing here changes a setting.
            """)
            .font(.footnote)
            .foregroundStyle(.secondary)

            Button {
                Task {
                    probing = true
                    probe = await store.probeCapabilities()
                    probing = false
                }
            } label: {
                HStack {
                    Label("Probe chip", systemImage: "wave.3.right")
                    Spacer()
                    if probing { ProgressView() }
                }
            }
            .disabled(probing || !store.raceReady)

            if !store.raceReady {
                Button("Reopen Airoha channel", systemImage: "arrow.clockwise") {
                    Task { probing = true; await store.reopenRaceChannel(); probing = false }
                }
                .disabled(probing)
            }

            ForEach(probe, id: \.self) { line in
                Text(line)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
            }

            if !probe.isEmpty {
                Button("Copy result", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = probe.joined(separator: "\n")
                }
            }
        } header: {
            Text("Chip capabilities")
        } footer: {
            if !store.raceReady {
                Text("The Airoha channel is not open. It lives on a second GATT server the headphones expose alongside the main one; if the app attached to the wrong one, reconnecting usually fixes it.")
            }
        }
    }

    // Sekcja testu przycisku M zostala usunieta.
    //
    // Wynik byl jednoznacznie negatywny: przy przycisku ustawionym na noAction
    // i wlaczonym ENABLE_FW_NOTIFY nacisniecia nie generuja ZADNEJ ramki na kanale
    // RACE. Razem z tym, ze charakterystyka 0000000C odrzuca kazda subskrypcje,
    // zamyka to temat - sluchawki nie raportuja nacisniec przycisku do hosta.
}
