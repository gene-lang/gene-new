// Platform SDK boundary only. The Gene host owns claims, queues and admission.
// All packets are u32le length + payload; stdout contains no diagnostics.
import Foundation
import AVFoundation
import Speech

enum VoiceFailure: Error, LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

func readExactly(_ count: Int) throws -> Data {
    var data = Data()
    while data.count < count {
        guard let part = try FileHandle.standardInput.read(upToCount: count - data.count), !part.isEmpty else {
            throw VoiceFailure.message("Audio input closed.")
        }
        data.append(part)
    }
    return data
}
func u32(_ data: Data, _ offset: Int) -> UInt32 {
    (0..<4).reduce(0) { $0 | (UInt32(data[offset + $1]) << ($1 * 8)) }
}
func readPacket() throws -> Data {
    let size = Int(u32(try readExactly(4), 0))
    guard size <= 65545 else { throw VoiceFailure.message("Audio packet exceeds its limit.") }
    return try readExactly(size)
}
func packet(_ data: Data) {
    var length = UInt32(data.count).littleEndian
    FileHandle.standardOutput.write(Data(bytes: &length, count: 4))
    FileHandle.standardOutput.write(data)
}
func control(_ value: [String: Any]) {
    packet(try! JSONSerialization.data(withJSONObject: value))
}
func json(_ data: Data) throws -> [String: Any] {
    guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw VoiceFailure.message("Expected a JSON control object.")
    }
    return value
}

// One converter per stream preserves resampler state across callback buffers.
final class Converter {
    let output: AVAudioFormat
    var converter: AVAudioConverter?
    init(output: AVAudioFormat) { self.output = output }
    func convert(_ input: AVAudioPCMBuffer?, emit: (AVAudioPCMBuffer) throws -> Void) throws {
        if let input, converter == nil { converter = AVAudioConverter(from: input.format, to: output) }
        guard let converter else { return }
        let frames = input.map { Int(ceil(Double($0.frameLength) * output.sampleRate / $0.format.sampleRate)) + 256 } ?? 1024
        guard let buffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: AVAudioFrameCount(frames)) else {
            throw VoiceFailure.message("Could not allocate an audio conversion buffer.")
        }
        var supplied = false
        var failure: NSError?
        let status = converter.convert(to: buffer, error: &failure) { _, state in
            if let input, !supplied { supplied = true; state.pointee = .haveData; return input }
            state.pointee = input == nil ? .endOfStream : .noDataNow
            return nil
        }
        if let failure { throw failure }
        if status == .error { throw VoiceFailure.message("Audio sample conversion failed.") }
        if buffer.frameLength > 0 { try emit(buffer) }
    }
}

@MainActor final class Speaker {
    let synthesizer = AVSpeechSynthesizer()
    let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: false)!
    var inPcm = false
    func speak(_ request: [String: Any]) async throws {
        let text = request["text"] as? String ?? ""
        guard !text.isEmpty, text.utf8.count <= 65536 else { throw VoiceFailure.message("Expected nonempty speech text, at most 64 KiB.") }
        let utterance = AVSpeechUtterance(string: text)
        let voice = request["voice"] as? String ?? ""
        let language = request["language"] as? String ?? "en-US"
        utterance.voice = voice.isEmpty ? AVSpeechSynthesisVoice(language: language) : AVSpeechSynthesisVoice(identifier: voice)
        guard utterance.voice != nil else { throw VoiceFailure.message("The requested macOS voice is not installed.") }
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * Float(max(0.5, min(2, request["rate"] as? Double ?? 1)))
        let converter = Converter(output: format)
        control(["ok": true])
        inPcm = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var finished = false
            let emit: (AVAudioPCMBuffer) throws -> Void = { buffer in
                guard let samples = buffer.int16ChannelData?[0] else { throw VoiceFailure.message("Expected mono s16le output.") }
                var bytes = Data(capacity: Int(buffer.frameLength) * 2)
                for index in 0..<Int(buffer.frameLength) {
                    var sample = samples[index].littleEndian
                    bytes.append(Data(bytes: &sample, count: 2))
                }
                var offset = 0
                while offset < bytes.count {
                    let end = min(bytes.count, offset + 32768)
                    packet(bytes.subdata(in: offset..<end)); offset = end
                }
            }
            synthesizer.write(utterance) { raw in
                guard !finished else { return }
                do {
                    guard let buffer = raw as? AVAudioPCMBuffer else { throw VoiceFailure.message("Unexpected macOS speech buffer.") }
                    if buffer.frameLength == 0 {
                        try converter.convert(nil, emit: emit)
                        finished = true; packet(Data()); self.inPcm = false; continuation.resume()
                    } else { try converter.convert(buffer, emit: emit) }
                } catch {
                    // After the success header, only PCM packets are legal.
                    // Closing on conversion failure preserves framing.
                    finished = true; continuation.resume(throwing: error)
                }
            }
        }
    }
}

@available(macOS 26, *)
@MainActor final class Recognition {
    let id: UInt32
    let transcriber: SpeechTranscriber
    let analyzer: SpeechAnalyzer
    let continuation: AsyncStream<AnalyzerInput>.Continuation
    let converter: Converter
    let inputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!
    var results: Task<Void, Error>?
    var cancelled = false
    var text = ""
    var count = 0
    var sequence: UInt32 = 0

    init(id: UInt32, locale: Locale, format: AVAudioFormat) async throws {
        self.id = id
        transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        analyzer = SpeechAnalyzer(modules: [transcriber])
        converter = Converter(output: format)
        let (inputs, sink) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(160))
        continuation = sink
        try await analyzer.prepareToAnalyze(in: format)
        results = Task { [weak self] in
            guard let self else { return }
            for try await result in transcriber.results {
                guard !cancelled else { return }
                let value = String(result.text.characters)
                let display = (text + " " + value).trimmingCharacters(in: .whitespacesAndNewlines)
                if result.isFinal { text = display }
                control(["type": "partial", "stream": id, "text": display])
            }
        }
        try await analyzer.start(inputSequence: inputs)
    }
    func emit(_ buffer: AVAudioPCMBuffer) throws {
        if case .dropped = continuation.yield(AnalyzerInput(buffer: buffer)) {
            throw VoiceFailure.message("SpeechAnalyzer input could not keep up; this utterance was cancelled.")
        }
    }
    func push(_ packet: Data) throws {
        guard !cancelled, packet.count >= 11, packet.count <= 649, packet[0] == 1,
              u32(packet, 5) == sequence, (packet.count - 9) % 2 == 0 else {
            throw VoiceFailure.message("Invalid or out-of-order microphone PCM.")
        }
        count += packet.count - 9
        guard count <= 3840000 else { throw VoiceFailure.message("Utterance exceeds 120 seconds.") }
        sequence += 1
        let frames = (packet.count - 9) / 2
        let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(frames))!
        input.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames {
            let lo = UInt16(packet[9 + i * 2]), hi = UInt16(packet[10 + i * 2])
            input.int16ChannelData![0][i] = Int16(bitPattern: lo | (hi << 8))
        }
        try converter.convert(input, emit: emit)
    }
    func finish() async throws {
        try converter.convert(nil, emit: emit)
        continuation.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        try await results?.value
        if !cancelled { control(["type": "final", "stream": id, "text": text]) }
    }
    func cancel() async {
        cancelled = true; continuation.finish(); results?.cancel()
        await analyzer.cancelAndFinishNow()
    }
}

@main struct MacSpeech {
    @MainActor static func main() async {
        var greeted = false
        do {
            let args = CommandLine.arguments
            let mode = args.count > 1 ? args[1] : "--tts"
            if mode == "--tts" {
                let speaker = Speaker()
                control(["ok": true, "rate": 24000, "channels": 1, "encoding": "s16le"])
                greeted = true
                while true {
                    let request = try json(await Task.detached { try readPacket() }.value)
                    do { try await speaker.speak(request) }
                    catch {
                        if speaker.inPcm { throw error }
                        control(["ok": false, "message": error.localizedDescription])
                    }
                }
            } else if #available(macOS 26, *) {
                let requested = Locale(identifier: args.count > 2 ? args[2] : "en-US")
                guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
                    throw VoiceFailure.message("SpeechAnalyzer does not support this language.")
                }
                let module = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
                if mode == "--install" {
                    if let install = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                        try await install.downloadAndInstall()
                    }
                    control(["ok": true]); return
                }
                guard await AssetInventory.status(forModules: [module]) == .installed else {
                    throw VoiceFailure.message("SpeechAnalyzer assets are not installed. Run the helper with --install and the language first.")
                }
                guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
                    throw VoiceFailure.message("SpeechAnalyzer has no compatible audio format.")
                }
                control(["ok": true])
                greeted = true
                var streams: [UInt32: Recognition] = [:]
                while true {
                    let data = try await Task.detached { try readPacket() }.value
                    if data.first == 1 {
                        guard data.count >= 11, let stream = streams[u32(data, 1)] else { throw VoiceFailure.message("Unknown speech stream.") }
                        try stream.push(data)
                    } else {
                        let value = try json(data)
                        let id = (value["stream"] as? NSNumber)?.uint32Value ?? 0
                        switch value["op"] as? String {
                        case "start":
                            guard id > 0, streams[id] == nil, streams.count < 4 else { throw VoiceFailure.message("Invalid speech stream admission.") }
                            streams[id] = try await Recognition(id: id, locale: locale, format: format)
                        case "end":
                            if let stream = streams[id] {
                                Task { do { try await stream.finish() } catch { control(["type": "error", "stream": id, "message": "SpeechAnalyzer could not finish this utterance."]) }; streams[id] = nil }
                            }
                        case "cancel":
                            if let stream = streams.removeValue(forKey: id) { await stream.cancel() }
                        default: throw VoiceFailure.message("Unknown speech command.")
                        }
                    }
                }
            } else { throw VoiceFailure.message("SpeechAnalyzer requires macOS 26 or later.") }
        } catch {
            if !greeted { control(["ok": false, "message": error.localizedDescription]) }
            // This can also be EOF during ordinary host shutdown. Diagnostics
            // use stderr so PCM framing remains intact; no text/audio is logged.
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
        }
    }
}
