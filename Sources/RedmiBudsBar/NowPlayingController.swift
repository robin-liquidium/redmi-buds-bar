import AppKit
import Combine
import ImageIO
import MediaCore

final class NowPlayingController: ObservableObject {
    @Published private(set) var track: NowPlayingTrack?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var sourceName = ""
    @Published private(set) var sourceIcon: NSImage?
    private var commandPending = false
    @Published private(set) var error: String?
    private var listener: Process?
    private var command: Process?
    private var commandTimeout: DispatchWorkItem?
    private var decoder = MediaStreamDecoder()

    func start() {
        guard listener == nil else { return }
        error = nil
        decoder = MediaStreamDecoder()
        do {
            let process = try makeProcess(["stream", "--micros", "--debounce=100"])
            let output = Pipe()
            process.standardOutput = output
            output.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil; return }
                DispatchQueue.main.async {
                    guard let self, self.listener === process else { return }
                    do {
                        for update in try self.decoder.append(data) { self.receive(update) }
                    } catch {
                        self.stop()
                        self.error = "Could not read playback information. Reopen the controls to try again."
                    }
                }
            }
            process.terminationHandler = { [weak self] process in
                DispatchQueue.main.async {
                    guard let self, self.listener === process else { return }
                    self.stop()
                    self.error = "Playback information is unavailable. Reopen the controls to try again."
                }
            }
            listener = process
            try process.run()
        } catch {
            stop()
            self.error = "Playback controls could not start. Try reopening the app."
        }
    }

    func stop() {
        let process = listener
        listener = nil
        (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        if process?.isRunning == true { process?.terminate() }
        commandTimeout?.cancel()
        commandTimeout = nil
        if command?.isRunning == true { command?.terminate() }
        command = nil
        commandPending = false
        decoder = MediaStreamDecoder()
        receive(nil)
    }

    func togglePlayback() { send(["send", "2"]) }
    func previousTrack() { send(["send", "5"]) }
    func nextTrack() { send(["send", "4"]) }
    func seek(to seconds: TimeInterval) {
        guard let track, track.duration > 0, seconds.isFinite else { return }
        send(["seek", String(Int64(min(max(0, seconds), track.duration) * 1_000_000))])
    }

    func openSource() {
        guard let id = track?.sourceBundleIdentifier,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    private func receive(_ update: NowPlayingTrack?) {
        guard update != track else { return }
        if update?.artworkData != track?.artworkData {
            artwork = update?.artworkData.flatMap { Data(base64Encoded: $0) }.flatMap { data in
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 128
                      ] as CFDictionary) else { return nil }
                return NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
            }
        }
        if update?.sourceBundleIdentifier != track?.sourceBundleIdentifier {
            let app = update.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0.sourceBundleIdentifier).first }
            sourceName = app?.localizedName ?? update?.sourceBundleIdentifier ?? ""
            sourceIcon = app?.icon
        }
        track = update
    }

    private func makeProcess(_ arguments: [String]) throws -> Process {
        guard let resources = Bundle.main.resourceURL, let frameworks = Bundle.main.privateFrameworksURL else {
            throw CocoaError(.fileNoSuchFile)
        }
        let script = resources.appendingPathComponent("mediaremote-adapter.pl")
        let framework = frameworks.appendingPathComponent("MediaRemoteAdapter.framework")
        guard FileManager.default.fileExists(atPath: script.path),
              FileManager.default.fileExists(atPath: framework.path) else { throw CocoaError(.fileNoSuchFile) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [script.path, framework.path] + arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
    }

    private func send(_ arguments: [String]) {
        guard listener?.isRunning == true, track != nil, !commandPending else { return }
        do {
            let process = try makeProcess(arguments)
            error = nil
            commandPending = true
            command = process
            process.terminationHandler = { [weak self] process in
                DispatchQueue.main.async {
                    guard let self, self.command === process else { return }
                    self.commandTimeout?.cancel()
                    self.commandTimeout = nil
                    self.command = nil
                    self.commandPending = false
                    if process.terminationStatus != 0 { self.error = "The playback command failed. Try again." }
                }
            }
            try process.run()
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, self.command === process, process.isRunning else { return }
                process.terminate()
                self.error = "The player did not respond. Try again."
            }
            commandTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)
        } catch {
            command = nil
            commandPending = false
            self.error = "The playback command could not start. Try again."
        }
    }
}
