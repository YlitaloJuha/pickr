// Makes a USB-connected iPhone's screen visible to AVFoundation, the way QuickTime Player's
// New Movie Recording does, and optionally records it. Used by scripts/demo-gifs.sh.
//
//   swift scripts/enable-ios-screen-capture.swift [--name <device name>] [--udid <udid>]
//       [--wait <seconds>]
//       Enables screen capture devices (kCMIOHardwarePropertyAllowScreenCaptureDevices = 1)
//       and lists the iPhone screens that appear, one per line:
//       "SCREEN<TAB><uniqueID><TAB><name><TAB>chosen|other". The chosen one has the given name
//       (as `xcrun devicectl list devices` shows it) or UDID, or is the only screen. Exit 0
//       when one is chosen, 2 when none is, 3 when camera access (which screen capture needs)
//       is denied.
//
//   swift scripts/enable-ios-screen-capture.swift --record <out.mov> [--name <device name>]
//       [--udid <udid>] [--started-file <path>] [--wait <seconds>]
//       Records that screen (video only, no audio) until SIGINT or SIGTERM, then finishes the
//       file. When the first frame is written it prints "RECORDING <seconds since 1970>" and
//       writes the same number to --started-file. Exit 0 when the file is complete.
//
// The CoreMediaIO switch applies to the process that sets it, which is why recording lives
// here too: a separate recorder such as ffmpeg sees the iPhone only if it enables it itself.
// Only the iPhone's screen device (muxed audio and video, model "iOS Device") is ever
// opened, never a camera such as Continuity Camera. Nothing on the iPhone is changed; while
// it is captured, iOS shows the clean 9:41 status bar.

import AVFoundation
import CoreMediaIO
import Foundation

struct Options {
    var name: String?
    var udid: String?
    var wait: TimeInterval = 10
    var record: URL?
    var startedFile: URL?
}

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data("enable-ios-screen-capture: \(message)\n".utf8))
    exit(code)
}

func parseOptions() -> Options {
    var options = Options()
    var arguments = CommandLine.arguments.dropFirst().makeIterator()
    while let argument = arguments.next() {
        switch argument {
        case "--name": options.name = arguments.next()
        case "--udid": options.udid = arguments.next()
        case "--wait": options.wait = arguments.next().flatMap(TimeInterval.init) ?? options.wait
        case "--record": options.record = arguments.next().map { URL(fileURLWithPath: $0) }
        case "--started-file": options.startedFile = arguments.next().map { URL(fileURLWithPath: $0) }
        default: fail("unknown argument \(argument)", code: 64)
        }
    }
    return options
}

/// QuickTime's switch: screen capture devices become visible to this process.
func allowScreenCaptureDevices() {
    var address = CMIOObjectPropertyAddress(
        mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
        mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
    )
    var allow: UInt32 = 1
    let status = CMIOObjectSetPropertyData(
        CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &allow
    )
    if status != 0 {
        fail("CoreMediaIO refused to enable screen capture devices (OSStatus \(status))", code: 1)
    }
}

/// Hex digits only, upper-cased, so "00008101-001A2B3C4D5E6F70" matches "00008101001a2b3c4d5e6f70".
func normalized(_ id: String) -> String {
    String(id.uppercased().filter(\.isHexDigit))
}

/// iPhone and iPad screens: muxed devices whose model is "iOS Device". Cameras never qualify.
func screenDevices() -> [AVCaptureDevice] {
    AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .muxed, position: .unspecified)
        .devices
        .filter { $0.hasMediaType(.muxed) && $0.modelID == "iOS Device" }
}

/// Device names with typographic and straight apostrophes treated alike.
func plainName(_ name: String) -> String {
    name.replacingOccurrences(of: "\u{2019}", with: "'").lowercased()
}

/// The screen with the given name or UDID (the screen's uniqueID is usually not the UDID),
/// else the only screen there is.
func chosenScreen(among devices: [AVCaptureDevice], options: Options) -> AVCaptureDevice? {
    if let name = options.name, !name.isEmpty,
       let device = devices.first(where: { plainName($0.localizedName) == plainName(name) }) {
        return device
    }
    if let udid = options.udid.map(normalized), !udid.isEmpty,
       let device = devices.first(where: { normalized($0.uniqueID) == udid }) {
        return device
    }
    return devices.count == 1 ? devices[0] : nil
}

/// Waits for the screens to appear (they come a moment after the switch), running the main
/// run loop so CoreMediaIO can publish them.
func waitForScreens(options: Options) -> [AVCaptureDevice] {
    let deadline = Date().addingTimeInterval(options.wait)
    repeat {
        let devices = screenDevices()
        if chosenScreen(among: devices, options: options) != nil { return devices }
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
    } while Date() < deadline
    return screenDevices()
}

func cameraAccess() -> AVAuthorizationStatus {
    let status = AVCaptureDevice.authorizationStatus(for: .video)
    guard status == .notDetermined else { return status }
    let done = DispatchSemaphore(value: 0)
    AVCaptureDevice.requestAccess(for: .video) { _ in done.signal() }
    while done.wait(timeout: .now()) == .timedOut {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }
    return AVCaptureDevice.authorizationStatus(for: .video)
}

/// Records one device to a movie file and reports when the first frame is written.
final class ScreenRecorder: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let output = AVCaptureMovieFileOutput()
    private let startedFile: URL?

    init(device: AVCaptureDevice, startedFile: URL?) throws {
        self.startedFile = startedFile
        super.init()
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            fail("the capture session cannot use \(device.localizedName)", code: 1)
        }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
        // Video only: no sound from the phone ends up in the file.
        output.connection(with: .audio)?.isEnabled = false
    }

    func start(to url: URL) {
        session.startRunning()
        output.startRecording(to: url, recordingDelegate: self)
    }

    func stop() {
        if output.isRecording {
            output.stopRecording()
        } else {
            exit(5)
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        let started = String(format: "%.3f", Date().timeIntervalSince1970)
        if let startedFile {
            try? Data((started + "\n").utf8).write(to: startedFile)
        }
        print("RECORDING \(started)")
        fflush(stdout)
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: (any Error)?) {
        session.stopRunning()
        if let error = error as NSError?,
           (error.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool) != true {
            fail("recording failed: \(error.localizedDescription)", code: 4)
        }
        exit(0)
    }
}

// MARK: - Main

let options = parseOptions()
allowScreenCaptureDevices()
let devices = waitForScreens(options: options)
let chosen = chosenScreen(among: devices, options: options)

guard let record = options.record else {
    for device in devices {
        let mark = device.uniqueID == chosen?.uniqueID ? "chosen" : "other"
        print("SCREEN\t\(device.uniqueID)\t\(device.localizedName)\t\(mark)")
    }
    if AVCaptureDevice.authorizationStatus(for: .video) == .denied {
        fail("camera access is denied for this terminal (System Settings > Privacy & Security > Camera)", code: 3)
    }
    exit(chosen == nil ? 2 : 0)
}

guard let device = chosen else {
    fail("no iPhone screen appeared, or none with that name (is it connected by USB, unlocked and trusted?)", code: 2)
}
switch cameraAccess() {
case .authorized:
    break
default:
    fail("camera access is needed to capture the iPhone screen: allow this terminal in System Settings > Privacy & Security > Camera", code: 3)
}

let recorder: ScreenRecorder
do {
    recorder = try ScreenRecorder(device: device, startedFile: options.startedFile)
} catch {
    fail("cannot open \(device.localizedName): \(error.localizedDescription)", code: 1)
}

// kqueue sees these signals even when the shell started this process with them ignored.
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let signalSources = [SIGINT, SIGTERM].map { number -> any DispatchSourceSignal in
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler { recorder.stop() }
    source.resume()
    return source
}

recorder.start(to: record)
withExtendedLifetime(signalSources) {
    dispatchMain()
}
