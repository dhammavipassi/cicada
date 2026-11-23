import AVFoundation
import Speech
@testable import LiveSubs

extension LingClient {
    func validateKeyForTest(_ key: String) async { await nextKeyValidation(key) }
}

extension ListenEngine {
    func detectForTest() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        b.frameLength = 48_000
        for i in 0..<48_000 { b.floatChannelData![0][i] = 0.2 * sin(Float(i) * 0.03) }
        detectForTest(using: b)
    }
}
