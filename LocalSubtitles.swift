import SwiftUI
import AppKit
import ScreenCaptureKit
import Speech
import Translation

// Capture callbacks and recognition request replacement share the main queue.
final class AudioReceiver: NSObject, SCStreamOutput {
    var request: SFSpeechAudioBufferRecognitionRequest?
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        request?.appendAudioSampleBuffer(sampleBuffer)
    }
}

@MainActor
final class SubtitleModel: NSObject, ObservableObject, SCStreamDelegate {
    @Published var source = "en-US"
    @Published var original = ""
    @Published var translated = "再生中の音声を、日本語字幕に。"
    @Published var status = "待機中"
    @Published var running = false
    @Published var busy = false
    @Published var floating = true
    @Published var configuration: TranslationSession.Configuration?
    private var capture: SCStream?
    private let receiver = AudioReceiver()
    private var recognizer: SFSpeechRecognizer?
    private var recognition: SFSpeechRecognitionTask?
    private var rotation: Task<Void, Never>?
    private var generation = UUID()
    private var recognitionID = UUID()
    private var updates: AsyncStream<String>.Continuation?

    func start() async {
        guard !busy, !running else { return }
        busy = true
        status = "音声認識の権限を確認中…"
        let permission = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard permission == .authorized else {
            status = "システム設定 → プライバシーとセキュリティ → 音声認識で許可してください。"
            busy = false
            return
        }
        guard let engine = SFSpeechRecognizer(locale: Locale(identifier: source)),
              engine.supportsOnDeviceRecognition else {
            status = "この言語の端末内音声認識を利用できません。別の言語を選ぶか、macOSの音声入力で言語データを準備してください。"
            busy = false
            return
        }
        recognizer = engine
        generation = UUID()
        original = ""
        translated = "音声を待っています…"
        configuration = .init(source: Locale.Language(identifier: source),
                              target: Locale.Language(identifier: "ja"))
        status = "翻訳用の言語データを準備中…"
    }

    func translate(using session: TranslationSession) async {
        let run = generation
        do {
            try await session.prepareTranslation()
            guard run == generation, !Task.isCancelled else { return }
            let (stream, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(1))
            updates = continuation
            try await startCapture()
            guard run == generation, !Task.isCancelled else { return }
            busy = false
            running = true
            status = "翻訳中 · 端末内処理"
            var previous = ""
            for await text in stream {
                guard run == generation, !Task.isCancelled else { break }
                guard !text.isEmpty, text != previous else { continue }
                let result = try await session.translate(text)
                guard run == generation, !Task.isCancelled else { break }
                translated = result.targetText
                previous = text
                // ponytail: latest-only updates limit load; sentence alignment can be added later.
                try await Task.sleep(for: .milliseconds(650))
            }
        } catch {
            guard run == generation else { return }
            await stop(message: "開始・翻訳に失敗しました: \(error.localizedDescription)")
        }
    }

    private func startCapture() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw NSError(domain: "LocalSubtitles", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "音声取得に使用するディスプレイがありません。"])
        }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let options = SCStreamConfiguration()
        options.capturesAudio = true
        options.excludesCurrentProcessAudio = true
        options.sampleRate = 16000
        options.channelCount = 1
        options.width = 2
        options.height = 2
        options.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let stream = SCStream(filter: filter, configuration: options, delegate: self)
        try stream.addStreamOutput(receiver, type: .audio, sampleHandlerQueue: .main)
        capture = stream
        beginRecognition()
        try await stream.startCapture()
        rotation = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(50)) } catch { return }
                self?.beginRecognition()
            }
        }
    }

    private func beginRecognition() {
        recognitionID = UUID()
        recognition?.cancel()
        receiver.request?.endAudio()
        let id = recognitionID
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        receiver.request = request
        recognition = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, id == self.recognitionID else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    self.original = text
                    self.updates?.yield(text)
                    if result.isFinal { self.beginRecognition(); return }
                }
                if let error {
                    await self.stop(message: "音声認識が停止しました: \(error.localizedDescription)")
                }
            }
        }
    }

    func stop(message: String = "停止しました") async {
        busy = true
        generation = UUID()
        recognitionID = UUID()
        rotation?.cancel()
        rotation = nil
        updates?.finish()
        updates = nil
        recognition?.cancel()
        recognition = nil
        receiver.request?.endAudio()
        receiver.request = nil
        let stream = capture
        capture = nil
        configuration = nil
        running = false
        if let stream { try? await stream.stopCapture() }
        status = message
        busy = false
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            guard self.capture === stream else { return }
            await self.stop(message: "音声取得が停止しました: \(error.localizedDescription)")
        }
    }
}

struct SubtitleView: View {
    @StateObject private var model = SubtitleModel()
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Picker("音声の言語", selection: $model.source) {
                    Text("英語").tag("en-US")
                    Text("中国語").tag("zh-CN")
                    Text("韓国語").tag("ko-KR")
                    Text("フランス語").tag("fr-FR")
                    Text("ドイツ語").tag("de-DE")
                    Text("スペイン語").tag("es-ES")
                }.frame(width: 215).disabled(model.running || model.busy)
                Text("→ 日本語").foregroundStyle(.secondary)
                Spacer()
                Button(model.running ? "停止" : "開始") {
                    Task { if model.running { await model.stop() } else { await model.start() } }
                }.buttonStyle(.borderedProminent).tint(.teal).disabled(model.busy)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(model.translated).font(.system(size: 27, weight: .medium))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    if !model.original.isEmpty {
                        Text(model.original).font(.body).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: 150)
            Divider()
            HStack(alignment: .top) {
                Text(model.status).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Toggle("最前面", isOn: $model.floating).toggleStyle(.checkbox)
                    .onChange(of: model.floating) { _, value in
                        NSApp.windows.filter { $0.title == "Local Subtitles" }.forEach {
                            $0.level = value ? .floating : .normal
                        }
                    }
            }
        }
        .padding(24).frame(minWidth: 620, minHeight: 360)
        .translationTask(model.configuration) { session in await model.translate(using: session) }
        .onAppear {
            NSApp.windows.filter { $0.title == "Local Subtitles" }.forEach {
                $0.level = .floating
                $0.collectionBehavior.insert(.fullScreenAuxiliary)
            }
        }
    }
}

@main
struct LocalSubtitlesApp: App {
    var body: some Scene {
        Window("Local Subtitles", id: "subtitles") { SubtitleView() }
            .defaultSize(width: 720, height: 420)
    }
}
