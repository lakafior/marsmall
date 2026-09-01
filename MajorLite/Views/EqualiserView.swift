import SwiftUI

/// The equaliser the M-button cycles but the official app only half exposes.
///
/// Two slots. Slot 1 is Marshall's own tuning and cannot be changed. Slot 2 holds
/// one of six presets. Pressing the M-button in equaliser mode switches between them.
struct EqualiserView: View {
    @Environment(DeviceStore.self) private var store
    @State private var busy = false

    var body: some View {
        List {
            Section {
                Picker("Active slot", selection: Binding(
                    get: { store.equaliserSlot ?? 1 },
                    set: { slot in Task { busy = true; await store.setEqualiserSlot(slot); busy = false } }
                )) {
                    Text("Slot 1").tag(1)
                    Text("Slot 2").tag(2)
                }
                .pickerStyle(.segmented)
                .disabled(busy || store.equaliserSlot == nil)
            } header: {
                Text("Active")
            } footer: {
                Text("Slot 1 is Marshall's own tuning and is fixed. The M-button switches between the two slots when it is set to Equaliser.")
            }

            Section {
                LabeledContent("Preset", value: "Marshall")
                    .foregroundStyle(.secondary)
            } header: {
                Text("Slot 1")
            } footer: {
                Text("Fixed by Marshall, nothing to choose here.")
            }

            Section {
                ForEach(MajorV.EqualiserPreset.allCases) { preset in
                    Button {
                        Task { busy = true; await store.setEqualiserPreset(preset); busy = false }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: store.equaliserPreset == preset
                                  ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(store.equaliserPreset == preset
                                                 ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.title).foregroundStyle(.primary)
                                Text(preset.caption)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                }
            } header: {
                Text("Slot 2")
            } footer: {
                Text("Slot 2 can hold any of these, including Marshall's own tuning. The five Custom bands still have to be set in the official Marshall app — see the note in EqualiserMath.swift for why.")
            }
        }
        .navigationTitle("Equaliser")
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if busy { ProgressView().controlSize(.large) } }
    }
}
