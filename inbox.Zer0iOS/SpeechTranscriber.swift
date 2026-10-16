import AVFoundation
import Observation
import Speech

@MainActor
@Observable
final class SpeechTranscriber {
    var transcript = ""
    var isRecording = false
    private(set) var isStarting = false
    private var audioEngine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var tapInstalled = false

    func start() async throws {
        guard !isRecording, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }

        let authorized = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard authorized else { throw SpeechError.notAuthorized }
        let recordPermission = await AVAudioApplication.requestRecordPermission()
        guard recordPermission else { throw SpeechError.microphoneDenied }

        cleanupCapture()
        InteractionFeedback.shared.suspendAudioForRecording()

        // A fresh engine for every capture session prevents AVAudioInputNode
        // from retaining a stale tap after interruptions or view transitions.
        let audioEngine = AVAudioEngine()
        self.audioEngine = audioEngine

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            throw SpeechError.recognizerUnavailable
        }

        transcript = ""
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            cleanupCapture()
            throw SpeechError.audioInputUnavailable
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
        tapInstalled = true
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            cleanupCapture()
            throw error
        }

        isRecording = true
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                if let result {
                    self?.transcript = result.bestTranscription.formattedString
                }
                if error != nil || result?.isFinal == true {
                    self?.stop()
                }
            }
        }
    }

    func stop() {
        cleanupCapture()
    }

    private func cleanupCapture() {
        if let audioEngine {
            audioEngine.stop()
        }
        if tapInstalled, let audioEngine {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        audioEngine = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

private enum SpeechError: LocalizedError {
    case notAuthorized, microphoneDenied, recognizerUnavailable, audioInputUnavailable
    var errorDescription: String? {
        switch self {
        case .notAuthorized: "Speech recognition permission is required for voice replies."
        case .microphoneDenied: "Microphone permission is required for voice replies."
        case .recognizerUnavailable: "Speech recognition is temporarily unavailable. Please try again."
        case .audioInputUnavailable: "The microphone input is unavailable. Check the current audio route and try again."
        }
    }
}
