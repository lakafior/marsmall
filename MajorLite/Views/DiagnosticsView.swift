import SwiftUI
import CoreBluetooth

/// Raw view of everything the headphones expose.
///
/// This mirrors what the `marshall-recon` command line tool prints. It is here
/// because the protocol is only partly decoded: when a value looks wrong, the
/// bytes tell you why and guessing does not.
struct DiagnosticsView: View {
    @Environment(DeviceStore.self) private var store
    @State private var reading = false
    @State private var copied = false
    @State private var busy = false
    @State private var diff: [String] = []

    var body: some View {
        List {
            Section {
                Text("""
                Every characteristic the headphones expose, exactly as they returned it. \
                Values are read on entry; pull to refresh or tap Read all to re-read.
                """)
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            ForEach(groups, id: \.service) { group in
                Section("Service \(MajorV.label(for: group.service))") {
                    ForEach(group.rows) { row($0) }
                }
            }

            Section {
                Text("""
                Save a snapshot, change one setting in the official Marshall app, \
                then compare. Whatever moved is the characteristic that carries it.
                """)
                .font(.footnote)
                .foregroundStyle(.secondary)

                Button("Save snapshot", systemImage: "camera") {
                    Task { busy = true; await store.saveSnapshot(); busy = false }
                }
                .disabled(busy)

                Button("Compare with snapshot", systemImage: "arrow.left.arrow.right") {
                    Task { busy = true; diff = await store.compareWithSnapshot(); busy = false }
                }
                .disabled(busy || store.snapshot == nil)

                ForEach(diff, id: \.self) { line in
                    Text(line).font(.caption2.monospaced()).textSelection(.enabled)
                }
                if !diff.isEmpty {
                    Button("Copy differences", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = diff.joined(separator: "\n")
                    }
                }
            } header: {
                Text("Compare")
            } footer: {
                if let t = store.snapshotTaken {
                    Text("Snapshot taken \(t.formatted(date: .omitted, time: .standard)).")
                }
            }

            Section("Channels") {
                LabeledContent("Characteristics discovered", value: "\(store.entries.count)")
                LabeledContent("Values read", value: "\(store.rawValues.count)")
                if let c = store.chargeStatus {
                    LabeledContent("charge_status (RACE 0x0009)",
                                   value: String(format: "0x%02X", c))
                }
                LabeledContent("Airoha RACE channel") {
                    Text(store.raceReady ? "open" : "unavailable")
                        .foregroundStyle(store.raceReady ? .green : .secondary)
                }
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.readEverything() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Read all") {
                    Task { reading = true; await store.readEverything(); reading = false }
                }
                .disabled(reading)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Copy report", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = store.diagnosticsReport()
                        copied = true
                    }
                    ShareLink(item: store.diagnosticsReport()) {
                        Label("Share report", systemImage: "square.and.arrow.up")
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .task { await store.readEverything() }
        .overlay {
            if reading || busy { ProgressView().controlSize(.large) }
        }
        .alert("Copied", isPresented: $copied) {
            Button("OK") { }
        } message: {
            Text("The full report is on the clipboard.")
        }
    }

    private struct Row: Identifiable {
        let service: CBUUID
        let characteristic: CBUUID
        let data: Data?
        var id: String { BLEClient.key(service, characteristic) }
    }

    /// Pogrupowane po serwisie - duplikaty tego samego UUID charakterystyki
    /// w roznych serwisach musza byc widoczne osobno.
    private var groups: [(service: CBUUID, rows: [Row])] {
        let rows = store.entries.map {
            Row(service: $0.service, characteristic: $0.characteristic,
                data: store.rawValues[BLEClient.key($0.service, $0.characteristic)])
        }
        return Dictionary(grouping: rows, by: \.service)
            .map { ($0.key, $0.value.sorted { $0.characteristic.uuidString < $1.characteristic.uuidString }) }
            .sorted { $0.0.uuidString < $1.0.uuidString }
    }

    @ViewBuilder
    private func row(_ r: Row) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(MajorV.label(for: r.characteristic)).font(.callout.monospaced())
                Spacer()
                if let name = MajorV.friendlyName(for: r.characteristic) {
                    Text(name).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let d = r.data {
                Text(Hex.describe(d))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else {
                Text("not read").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}

enum Hex {
    static func string(_ d: Data) -> String {
        d.map { String(format: "%02x", $0) }.joined()
    }

    /// Hex plus the numeric readings that matter for one and two byte values —
    /// most of these settings are exactly that.
    static func describe(_ d: Data) -> String {
        guard !d.isEmpty else { return "(empty)" }
        var parts = [string(d)]
        if let ascii = printable(d) { parts.append("\"\(ascii)\"") }
        switch d.count {
        case 1: parts.append("u8=\(d[0])")
        case 2:
            let le = UInt16(d[0]) | UInt16(d[1]) << 8
            let be = UInt16(d[0]) << 8 | UInt16(d[1])
            parts.append("u16le=\(le) u16be=\(be)")
        default: break
        }
        return parts.joined(separator: "  ")
    }

    static func printable(_ d: Data) -> String? {
        guard !d.isEmpty else { return nil }
        let ok = d.filter { $0 >= 0x20 && $0 < 0x7f }.count
        guard Double(ok) / Double(d.count) > 0.8 else { return nil }
        return String(decoding: d, as: UTF8.self)
    }
}
