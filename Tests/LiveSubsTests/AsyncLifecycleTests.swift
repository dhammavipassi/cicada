import AVFoundation
import Speech
import Testing
@testable import LiveSubs

@MainActor
@Suite(.serialized)
struct AsyncLifecycleTests {
    private enum TestFailure: Error { case microphone, output }

    private func wait(_ ns: UInt64 = 30_000_000) async {
        try? await Task.sleep(nanoseconds: ns)
    }

    private nonisolated func until(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return await condition()
    }

    private func buffer() -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16)!
        b.frameLength = 16
        return b
    }

    private func speechEngine(utterance: String = "old words") -> SpeakEngine {
        let settings = AppSettings()
        settings.speakEnabled = true
        settings.speakTo = "en"
        let e = SpeakEngine(settings: settings)
        e.preparedFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)
        e.chooseOutput = { nil }
        e.makeUtterance = { id in
            let (_, cont) = AsyncStream.makeStream(of: AnalyzerInput.self)
            return .init(id: id, input: cont, text: Task { utterance })
        }
        e.startCapture = { _, _, _ in }
        e.releaseDelayNanoseconds = 0
        return e
    }

    @Test func cancellationAfterReleaseCannotTranslatePlayOrRecord() async {
        let e = speechEngine()
        var translated = false, recorded = false
        var phases: [SpeakEngine.Phase] = []
        e.onLive = { phase, _, _ in phases.append(phase) }
        e.translate = { _, _, _, _ in translated = true; return "new words" }
        e.onUtterance = { _, _, _, _, _ in recorded = true }
        e.synthesizeOutput = { _, _, _ in [self.buffer()] }
        e.configurePlayback = { _, _ in }
        e.startOutput = { }
        e.playOutput = { _, done in done(true) }

        e.pressBegan()
        e.pressEnded()
        e.pressCancelled()
        await wait()
        #expect(!translated && !recorded && !phases.contains(.translating))
        #expect(e.phase == .idle && phases.last == .idle)
    }

    @Test func cancellingTranslationIgnoresLateReplyAndPlayback() async {
        let e = speechEngine()
        var releaseTranslation: (() -> Void)?
        let translated = Task {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                releaseTranslation = { cont.resume() }
            }
        }
        var played = false, recorded = false
        var phases: [SpeakEngine.Phase] = []
        e.onLive = { phase, _, _ in phases.append(phase) }
        e.translate = { _, _, _, _ in await translated.value; return "late translation" }
        e.onUtterance = { _, _, _, _, _ in recorded = true }
        e.synthesizeOutput = { _, _, _ in played = true; return [self.buffer()] }
        e.pressBegan()
        e.pressEnded()
        await wait()
        #expect(phases.contains(.translating))
        e.pressCancelled()
        releaseTranslation?()
        await wait()
        #expect(!played && !recorded && e.phase == .idle)
        #expect(phases.last == .idle)
    }

    @Test func closingAWorkingRehearsalCancelsTheEngineBeforeScoring() async {
        let e = speechEngine()
        let tester = SpeakTester(speak: e, ling: LingClient(readStoredKey: false), settings: e.settings)
        var played = false, recorded = false
        e.translate = { _, _, _, _ in
            tester.cancel()
            return "rehearsal must not play"
        }
        e.synthesizeOutput = { _, _, _ in played = true; return [self.buffer()] }
        e.onUtterance = { _, _, _, _, _ in recorded = true }
        e.pressBegan()
        e.pressEnded()
        await wait()
        #expect(tester.phase == .idle && !played && !recorded && e.phase == .idle)
        #expect(e.activeProbe == nil)
    }

    @Test func failedMicrophoneProducesAnIdleTerminalState() async {
        let e = speechEngine()
        var phases: [SpeakEngine.Phase] = []
        e.onLive = { phase, _, _ in phases.append(phase) }
        e.startCapture = { _, _, _ in throw TestFailure.microphone }
        e.pressBegan()
        #expect(e.phase == .idle)
        #expect(phases == [.listening, .idle])
    }

    @Test func synthesisAndOutputFailuresAreNotSuccess() async {
        let e = speechEngine()
        e.synthesizeOutput = { _, _, _ in [] }
        #expect(await e.speak("hello", language: "en") == false)

        e.synthesizeOutput = { _, _, _ in [self.buffer()] }
        e.configurePlayback = { _, _ in }
        e.startOutput = { throw TestFailure.output }
        #expect(await e.speak("hello", language: "en") == false)
    }

    @Test func streamFailureAfterAudioIsNotReportedAsSuccess() async {
        let e = speechEngine()
        e.configurePlayback = { _, _ in }
        e.startOutput = { }
        e.playOutput = { _, done in done(true) }
        let route = SpeakEngine.VoiceRoute.stream { _ in
            AsyncThrowingStream { cont in
                cont.yield(Data(repeating: 0, count: 32))
                cont.finish(throwing: TestFailure.output)
            }
        }
        #expect(await e.speak("hello", language: "en", route: route) == false)
    }

    @Test func successivePlaybackIsNotCancelledByItsOwnReset() async {
        let e = speechEngine()
        e.synthesizeOutput = { _, _, _ in [self.buffer()] }
        e.configurePlayback = { _, _ in }
        e.startOutput = { }
        e.playOutput = { _, done in done(true) }
        #expect(await e.speak("one", language: "en"))
        #expect(await e.speak("two", language: "en"))
    }

    @Test func utteranceIsRecordedOnlyAfterPlaybackFinishes() async {
        let e = speechEngine()
        var finishPlayback: ((Bool) -> Void)?
        var recorded = 0
        var seen: [SpeakEngine.Phase] = []
        var translateCalls = 0
        e.onLive = { phase, _, _ in seen.append(phase) }
        e.translate = { _, _, _, _ in translateCalls += 1; return "translation" }
        e.synthesizeOutput = { _, _, _ in [self.buffer()] }
        e.configurePlayback = { _, _ in }
        e.startOutput = { }
        e.playOutput = { _, done in finishPlayback = done }
        e.onUtterance = { _, _, _, _, _ in recorded += 1 }
        e.pressBegan()
        e.pressEnded()
        #expect(await until { e.phase == .speaking && finishPlayback != nil }, "phases=\(seen) translations=\(translateCalls)")
        #expect(recorded == 0)
        finishPlayback?(false)
        await wait()
        #expect(e.phase == .idle && recorded == 0)

        e.pressBegan()
        e.pressEnded()
        #expect(await until { e.phase == .speaking && finishPlayback != nil }, "phases=\(seen) translations=\(translateCalls)")
        #expect(recorded == 0)
        finishPlayback?(true)
        await wait()
        #expect(e.phase == .idle && recorded == 1)
    }

    @Test func cancellingPlaybackReturnsAndPreventsRecord() async {
        let e = speechEngine()
        var finishPlayback: ((Bool) -> Void)?
        var recorded = false
        e.translate = { _, _, _, _ in "translation" }
        e.synthesizeOutput = { _, _, _ in [self.buffer()] }
        e.configurePlayback = { _, _ in }
        e.startOutput = { }
        e.playOutput = { _, done in finishPlayback = done }
        e.onUtterance = { _, _, _, _, _ in recorded = true }
        e.pressBegan()
        e.pressEnded()
        #expect(await until { e.phase == .speaking && finishPlayback != nil })
        e.pressCancelled()
        finishPlayback?(true)
        await wait()
        #expect(e.phase == .idle && !recorded)
    }

    @Test func oldKeyValidationCannotOverwriteLatestCheck() async {
        let ling = LingClient(readStoredKey: false)
        var calls = 0
        var finishOld: (() -> Void)?
        ling.checkTransport = { _, _, _, _ in
            calls += 1
            if calls == 1 {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    finishOld = { cont.resume() }
                }
                throw LingClient.Failure.invalidKey
            }
            return [:]
        }
        async let old: Void = ling.validateKeyForTest("test-old")
        #expect(await until { finishOld != nil })
        #expect(ling.keyState == .checking)
        async let new: Void = ling.validateKeyForTest("test-new")
        await new
        if case .ok = ling.keyState {} else { Issue.record("new key validation did not complete") }
        finishOld?()
        await old
        #expect(ling.keyState != .invalid)
        if case .ok = ling.keyState {} else { Issue.record("old validation replaced the new key state") }
    }

    @Test func oldTargetTranslationCannotReplaceNewTarget() async {
        let settings = AppSettings()
        let e = ListenEngine(settings: settings)
        e.startMeetingForTest()
        var finishOld: (() -> Void)?
        let old = Task {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                finishOld = { cont.resume() }
            }
        }
        var calls = 0
        e.translateText = { _, _, target, _, _ in
            #expect(target == "ja" || calls == 0)
            calls += 1
            if calls == 1 { await old.value }
            return calls == 1 ? "old target" : "new target"
        }
        var translations: [String] = []
        e.onTranslated = { _, text in translations.append(text) }
        e.acceptSegmentForTest("one sentence")
        #expect(await until { calls == 1 })
        settings.target = "ja"
        e.targetChanged()
        #expect(await until { translations == ["new target"] }, "calls=\(calls) translations=\(translations)")
        finishOld?()
        await wait()
        #expect(translations == ["new target"])
    }

    @Test func oldMeetingTranslationCannotWriteIntoNewMeeting() async {
        let e = ListenEngine(settings: AppSettings())
        var finishOld: (() -> Void)?
        let old = Task {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                finishOld = { cont.resume() }
            }
        }
        e.translateText = { _, _, _, _, _ in await old.value; return "previous meeting" }
        var translated = false
        e.onTranslated = { _, _ in translated = true }
        e.acceptSegmentForTest("first meeting")
        e.stop()
        e.startMeetingForTest()
        e.acceptSegmentForTest("next meeting")
        finishOld?()
        await wait()
        #expect(!translated)
    }

    @Test func oldDetectionCannotPolluteNewMeeting() async {
        let e = ListenEngine(settings: AppSettings())
        var finishOld: (() -> Void)?
        let old = Task {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                finishOld = { cont.resume() }
            }
        }
        e.rankLanguages = { _, _ in
            await old.value
            return [.init(lang: sourceLanguages[0], confidence: 0.99, chars: 20, text: "wrong language", score: 0.99)]
        }
        e.detectForTest()
        e.stop()
        e.startMeetingForTest()
        finishOld?()
        await wait()
        #expect(e.activeLang == nil && !e.detecting)
    }

    @Test func oldSuccessfulKeyValidationCannotOverwriteRemovalOrNewerFailure() async {
        let ling = LingClient(readStoredKey: false)
        var calls = 0
        var finishOld: (() -> Void)?
        ling.checkTransport = { _, _, _, _ in
            calls += 1
            if calls == 1 {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    finishOld = { cont.resume() }
                }
                return [:]
            }
            throw LingClient.Failure.invalidKey
        }
        async let old: Void = ling.validateKeyForTest("test-old")
        #expect(await until { finishOld != nil })
        async let newer: Void = ling.validateKeyForTest("test-new")
        await newer
        #expect(ling.keyState == .invalid)
        finishOld?()
        await old
        #expect(ling.keyState == .invalid)

        var finishRateLimited: (() -> Void)?
        calls = 0
        ling.checkTransport = { _, _, _, _ in
            calls += 1
            if calls == 1 {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    finishRateLimited = { cont.resume() }
                }
                throw LingClient.Failure.rateLimited
            }
            throw LingClient.Failure.invalidKey
        }
        async let oldRateLimited: Void = ling.validateKeyForTest("test-old-429")
        #expect(await until { finishRateLimited != nil })
        async let newerInvalid: Void = ling.validateKeyForTest("test-new-401")
        await newerInvalid
        #expect(ling.keyState == .invalid)
        finishRateLimited?()
        await oldRateLimited
        #expect(ling.keyState == .invalid)
    }

    @Test func rapidSessionBeginProducesUniqueIDsAndDeletesCleanly() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cicada-session-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SessionStore(root: dir)
        let first = store.begin()
        store.append(TranscriptLine(id: "l1", t: 1, speaker: "them", src: "hello", dst: nil, srcLang: "en", dstLang: "zh"))
        store.end()

        let second = store.begin()
        store.append(TranscriptLine(id: "l2", t: 1, speaker: "them", src: "world", dst: nil, srcLang: "en", dstLang: "zh"))
        store.end()

        #expect(first.id != second.id)
        #expect(store.sessions.count == 2)
        #expect(FileManager.default.fileExists(atPath: store.folder(first.id).appendingPathComponent("session.json").path))
        #expect(FileManager.default.fileExists(atPath: store.folder(second.id).appendingPathComponent("session.json").path))

        store.delete(first.id)
        #expect(store.persistenceError == nil)
        #expect(store.sessions.map(\.id) == [second.id])
        #expect(!FileManager.default.fileExists(atPath: store.folder(first.id).path))
    }
}
