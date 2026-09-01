import Foundation

/// Kept for the record. **Sending band definitions alone does not change the sound.**
///
/// The band command (`0x0E2B`) is fully decoded and this file reproduces its payload
/// byte for byte. It is not enough: the DSP also needs `PEQ_REALTIME` (`0x0E03`),
/// a 441-byte block of computed filter coefficients laid out as four ~110-byte
/// elements. Changing one band scatters edits across the whole block in amounts
/// that vary by band, so there is no clean per-band region to fill in — decoding it
/// means working out the fixed-point format and the element layout from scratch.
///
/// Tried and measured: with only `0x0E2B` sent, the headphones report the new bands
/// but sound identical.
///
/// ---
///
/// The headroom value the headphones expect alongside the band gains.
///
/// It is not simply the largest gain: neighbouring bands overlap and add up, so
/// `[0, 0, +1.20, +6.00, 0]` produced 6.22 dB on the wire, not 6.00. The device
/// pre-attenuates by the true peak of the combined response so a boost cannot clip.
///
/// Reproducing it takes a standard RBJ peaking biquad per band, cascaded, sampled
/// across the audible range. Checked against ten captured packets: seven match to
/// the byte, the other three differ by a single hundredth of a decibel — the
/// official app's own sweep resolution, not a modelling error. That is a
/// pre-attenuation value, so 0.01 dB is inaudible and harmless.
enum EqualiserMath {

    private static let sampleRate = 44_100.0

    /// Peak of the combined magnitude response, in hundredths of a decibel,
    /// clamped at zero — a cut needs no headroom.
    static func headroomCentiDB(for gains: [Double]) -> UInt32 {
        var peak = -99.0
        // Log-spaced sweep over the audible band. Rounding down matches the
        // official app more often than rounding to nearest.
        for i in 0..<1000 {
            let f = 20 * pow(20_000 / 20, Double(i) / 999)
            let w = 2 * .pi * f / sampleRate
            var total = 0.0
            for (band, gain) in zip(MajorV.equaliserBands, gains) {
                total += magnitudeDB(at: w, frequency: band.frequency, q: band.q, gainDB: gain)
            }
            peak = max(peak, total)
        }
        return UInt32(max(0, (peak * 100).rounded(.down)))
    }

    /// One RBJ peaking-EQ section, evaluated on the unit circle.
    private static func magnitudeDB(at w: Double, frequency: Double,
                                    q: Double, gainDB: Double) -> Double {
        guard gainDB != 0 else { return 0 }
        let a = pow(10, gainDB / 40)
        let w0 = 2 * .pi * frequency / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cosW0 = cos(w0)

        let a0 = 1 + alpha / a
        let b0 = (1 + alpha * a) / a0
        let b1 = (-2 * cosW0) / a0
        let b2 = (1 - alpha * a) / a0
        let a1 = (-2 * cosW0) / a0
        let a2 = (1 - alpha / a) / a0

        let zr = cos(w), zi = -sin(w)
        let z2r = cos(2 * w), z2i = -sin(2 * w)
        let nr = b0 + b1 * zr + b2 * z2r
        let ni = b1 * zi + b2 * z2i
        let dr = 1 + a1 * zr + a2 * z2r
        let di = a1 * zi + a2 * z2i

        return 10 * log10((nr * nr + ni * ni) / (dr * dr + di * di))
    }

    /// The 193-byte payload of the `0x0E2B` command.
    static func payload(for gains: [Double]) -> Data {
        func i32(_ v: Int32) -> [UInt8] { withUnsafeBytes(of: v.littleEndian, Array.init) }
        func u32(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.littleEndian, Array.init) }

        var bytes = [UInt8](repeating: 0, count: 5)
        for (band, gain) in zip(MajorV.equaliserBands, gains) {
            bytes += [0x01, 0x02]
            bytes += i32(Int32((band.frequency * 100).rounded()))
            bytes += i32(Int32((gain * 100).rounded()))
            bytes += i32(Int32((band.frequency / band.q * 100).rounded()))
            bytes += i32(Int32((band.q * 100).rounded()))
        }
        bytes += [UInt8](repeating: 0, count: 90)
        let headroom = headroomCentiDB(for: gains)
        bytes += u32(headroom) + u32(headroom)
        return Data(bytes)
    }
}
