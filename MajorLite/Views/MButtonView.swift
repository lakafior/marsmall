import SwiftUI

/// Result of testing one action by hand.
enum ActionTestResult: String, CaseIterable, Identifiable {
    case untested, works, noEffect

    var id: String { rawValue }

    var title: String {
        switch self {
        case .untested: "Untested"
        case .works: "Works"
        case .noEffect: "No effect"
        }
    }

    var symbol: String {
        switch self {
        case .untested: "circle.dotted"
        case .works: "checkmark.circle.fill"
        case .noEffect: "xmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .untested: .secondary
        case .works: .green
        case .noEffect: .red
        }
    }
}

/// Remembers the outcome of each manual test across launches.
@Observable
final class ActionTestLog {
    private static let key = "actionTestResults"
    private var results: [String: String]

    init() {
        results = (UserDefaults.standard.dictionary(forKey: Self.key) as? [String: String]) ?? [:]
    }

    func result(for action: MajorV.ButtonAction) -> ActionTestResult {
        results[action.hex].flatMap(ActionTestResult.init(rawValue:)) ?? .untested
    }

    func set(_ result: ActionTestResult, for action: MajorV.ButtonAction) {
        results[action.hex] = result == .untested ? nil : result.rawValue
        UserDefaults.standard.set(results, forKey: Self.key)
    }

    func reset() {
        results.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.key)
    }

    func count(_ result: ActionTestResult) -> Int {
        MajorV.ButtonAction.allCases.filter { self.result(for: $0) == result }.count
    }
}

/// Every action the protocol carries, so each one can be tried by hand.
///
/// The Marshall app exposes four of these for Major V. The other twenty are
/// accepted by the firmware on write but were not observed to do anything —
/// this screen exists to check that claim properly, one action at a time.
struct MButtonView: View {
    @Environment(DeviceStore.self) private var store
    @State private var log = ActionTestLog()
    @State private var applying: MajorV.ButtonAction?

    var body: some View {
        List {
            Section {
                Text("""
                Pick an action to write it to the headphones, then press the M-button \
                and record what happened. Testing is more reliable with no other device \
                connected, so the action is not intercepted somewhere else.
                """)
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Section("Supported by the Marshall app") {
                ForEach(MajorV.ButtonAction.allCases.filter(\.isOfficial)) { row($0) }
            }

            Section {
                ForEach(MajorV.ButtonAction.allCases.filter { !$0.isOfficial }) { row($0) }
            } header: {
                Text("Carried by the protocol, unverified")
            } footer: {
                Text("\(log.count(.works)) confirmed working · \(log.count(.noEffect)) with no effect · \(log.count(.untested)) untested")
            }

            Section {
                Button("Reset test results", role: .destructive) { log.reset() }
            }
        }
        .navigationTitle("M-Button")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func row(_ action: MajorV.ButtonAction) -> some View {
        let isActive = store.buttonAction == action
        let result = log.result(for: action)

        HStack(spacing: 12) {
            Button {
                Task {
                    applying = action
                    await store.setButtonAction(action)
                    applying = nil
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(isActive ? Color.accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(action.title)
                            .foregroundStyle(.primary)
                        Text(action.hex)
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(applying != nil)

            if applying == action {
                ProgressView()
            } else {
                Menu {
                    ForEach(ActionTestResult.allCases) { option in
                        Button {
                            log.set(option, for: action)
                        } label: {
                            Label(option.title, systemImage: option.symbol)
                        }
                    }
                } label: {
                    Image(systemName: result.symbol)
                        .foregroundStyle(result.tint)
                        .font(.title3)
                        .frame(width: 32, height: 32)
                        .contentShape(.rect)
                }
            }
        }
    }
}
