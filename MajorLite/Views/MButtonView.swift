import SwiftUI

/// What the M-button does on a single press.
///
/// The protocol carries twenty-four actions, but this firmware only acts on four.
/// The rest can be written and read back — the button simply does nothing — which
/// was confirmed by trying each one by hand. They are listed for the record rather
/// than offered as choices.
struct MButtonView: View {
    @Environment(DeviceStore.self) private var store
    @State private var applying: MajorV.ButtonAction?

    private var supported: [MajorV.ButtonAction] {
        MajorV.ButtonAction.allCases.filter(\.isOfficial)
    }

    private var unsupported: [MajorV.ButtonAction] {
        MajorV.ButtonAction.allCases.filter { !$0.isOfficial }
    }

    var body: some View {
        List {
            Section {
                ForEach(supported) { action in
                    Button {
                        Task {
                            applying = action
                            await store.setButtonAction(action)
                            applying = nil
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: store.buttonAction == action
                                  ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(store.buttonAction == action
                                                 ? Color.accentColor : .secondary)
                            Text(action.title).foregroundStyle(.primary)
                            Spacer(minLength: 0)
                            if applying == action { ProgressView() }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .disabled(applying != nil)
                }
            } footer: {
                Text("A single press of the M-button. Double press is fixed in firmware and cannot be changed.")
            }

            Section {
                ForEach(unsupported) { action in
                    HStack {
                        Text(action.title)
                        Spacer()
                        Text(action.hex)
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                    .foregroundStyle(.secondary)
                }
            } header: {
                Text("Carried by the protocol, ignored by this firmware")
            } footer: {
                Text("The headphones accept these values and report them back, but the button does nothing. Tested one by one.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("M-Button")
        .navigationBarTitleDisplayMode(.inline)
    }
}
