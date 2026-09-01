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

                NavigationLink {
                    CustomEqualiserView()
                } label: {
                    Label("Custom bands", systemImage: "slider.vertical.3")
                }
            } header: {
                Text("Slot 2")
            } footer: {
                Text("Slot 2 can hold any of these, including Marshall's own tuning. Custom gives you five bands to set yourself — still experimental, see the screen for what is and is not known.")
            }
            Section {
                ForEach(6...11, id: \.self) { raw in
                    Button {
                        Task { busy = true; await store.tryPreset(UInt8(raw)); busy = false }
                    } label: {
                        HStack {
                            Text("Preset \(raw)")
                            Spacer()
                            Text(String(format: "0x%02X", raw))
                                .font(.caption.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                }
            } header: {
                Text("Beyond the official list")
            } footer: {
                Text("""
                A teardown of the Android Marshall app lists twelve preset ids where \
                this model only offers six, so the firmware may carry more. The \
                numbering there does not match what was measured here, so these are \
                shown as plain numbers rather than guessed names.

                Tapping one writes it and reads back. If the value does not stick, \
                the firmware rejected it and nothing changed.
                """)
            }
        }
        .navigationTitle("Equaliser")
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if busy { ProgressView().controlSize(.large) } }
    }
}
