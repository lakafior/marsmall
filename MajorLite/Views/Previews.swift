#if DEBUG
import SwiftUI

/// Sample state so the screens can be designed in the Xcode canvas.
/// The simulator has no Bluetooth, so this is the only way to see the
/// connected UI without deploying to a phone.
extension DeviceStore {
    static var preview: DeviceStore {
        let s = DeviceStore()
        s.model = "MAJOR V"
        s.firmware = "6.4.9"
        s.hardware = "5.0.0"
        s.manufacturer = "Marshall Group AB"
        s.serial = "73400553E445C4B0356766"
        s.batteryPercent = 79
        s.interactionSounds = true
        s.batteryPreservation = .max
        s.autoOffTimers = [
            .init(id: 0, type: 1, seconds: 10800),
            .init(id: 1, type: 2, seconds: 1200),
        ]
        s.buttonAction = .voiceAssistant
        s.nowPlaying = [
            1: "Związki jednopłciowe w potransformacyjnej Polsce",
            2: "Podcastex - podcast o latach 90",
            3: "25 June 2026",
        ]
        return s
    }
}

#Preview("Device") {
    NavigationStack {
        DeviceView().navigationTitle("Major V")
    }
    .environment(DeviceStore.preview)
}

#Preview("M-Button") {
    NavigationStack {
        MButtonView()
    }
    .environment(DeviceStore.preview)
}
#endif
