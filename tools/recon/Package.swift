// swift-tools-version: 5.9
import PackageDescription

// Zero zaleznosci zewnetrznych - buduje sie offline, bez pobierania czegokolwiek.
let package = Package(
    name: "marshall-recon",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "marshall-recon",
            path: "Sources/marshall-recon",
            linkerSettings: [
                // macOS (TCC) wymaga NSBluetoothAlwaysUsageDescription w Info.plist,
                // inaczej ubija proces w momencie dotkniecia CoreBluetooth.
                // Goly plik wykonywalny nie ma bundla, wiec wszywamy plist
                // bezposrednio w sekcje __TEXT,__info_plist pliku Mach-O.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/Info.plist",
                ])
            ]
        )
    ]
)
