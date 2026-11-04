//
//  DisplayAudio.swift
//  StarPlayrXMac
//
//  Copyright © 2026 Todd Bruss. All rights reserved.
//
//  Sound follows the panel across displays. When the Mac plays through a display's own speakers
//  and there are several such displays, the radio is sent to the speakers of the display the
//  StarPlayrX panel is on, by making them the Mac's sound output, so the volume keys and slider
//  work on the speakers that are playing. Nothing happens unless the system output is a
//  display's speakers to begin with.
//
//  Tying a speaker to a screen:
//  • HDMI / DisplayPort audio: the device is named after the display ("DELL U2720Q").
//  • USB / Thunderbolt display audio (LG UltraFine, Studio Display, Pro Display XDR), where every
//    display's speaker has the same name: the USB audio device sits behind PCIe controller
//    `apciecN`, and the display's DisplayPort link behind USB-C port controller `hpmN`; the same N
//    is the same port on the Mac. The display is found by its EDID serial number.
//

import AppKit
import CoreAudio
import IOKit

enum DisplayAudio {
    /// The output device (Core Audio UID) for `screen`'s speakers, if the system output is a
    /// display's speakers and `screen` has its own. Nil means "leave the sound where it is".
    static func device(for screen: NSScreen) -> String? {
        let outputs = outputDevices()
        guard let current = systemOutput(), let now = outputs.first(where: { $0.id == current }),
              isDisplay(now, among: outputs) else { return nil }
        return outputs.first { matches($0, screen: screen, among: outputs) }?.uid
    }

    /// The Core Audio UID of the Mac's sound output right now.
    static func systemOutputUID() -> String? {
        let id = systemOutput()
        return outputDevices().first(where: { $0.id == id })?.uid
    }

    /// Whether the device with this UID is already the Mac's sound output.
    static func isSystemOutput(_ uid: String) -> Bool {
        outputDevices().first(where: { $0.uid == uid })?.id == systemOutput()
    }

    /// Makes the device with this UID the Mac's sound output, and its alert-sound output too.
    /// The volume keys and slider also turn the alert device up and down, so left on the other
    /// display it made both displays' volumes move together.
    static func makeSystemOutput(_ uid: String) {
        guard var id = outputDevices().first(where: { $0.uid == uid })?.id else { return }
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice] {
            let current: AudioObjectID? = property(AudioObjectID(kAudioObjectSystemObject), selector)
            guard current != id else { continue }
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                       UInt32(MemoryLayout<AudioObjectID>.size), &id)
        }
    }

    // MARK: Core Audio

    struct Device { let id: AudioObjectID; let uid: String; let name: String; let transport: UInt32 }

    private static func outputDevices() -> [Device] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                     mScope: kAudioObjectPropertyScopeOutput,
                                                     mElement: kAudioObjectPropertyElementMain)
            var bytes: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &bytes) == noErr, bytes > 0,
                  let uid: CFString = property(id, kAudioDevicePropertyDeviceUID),
                  let name: CFString = property(id, kAudioObjectPropertyName) else { return nil }
            let transport: UInt32 = property(id, kAudioDevicePropertyTransportType) ?? 0
            return Device(id: id, uid: uid as String, name: name as String, transport: transport)
        }
    }

    private static func systemOutput() -> AudioObjectID? {
        property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
    }

    private static func property<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { value.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, value) == noErr else { return nil }
        return value.load(as: T.self)
    }

    // MARK: Which speaker is which display's

    /// A display's speakers: tied to some connected screen.
    private static func isDisplay(_ device: Device, among all: [Device]) -> Bool {
        NSScreen.screens.contains { matches(device, screen: $0, among: all) }
    }

    private static func matches(_ device: Device, screen: NSScreen, among all: [Device]) -> Bool {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              CGDisplayIsBuiltin(number) == 0 else { return false }
        switch device.transport {
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            // Named after the display; "LG UltraFine (2)" is how macOS tells two alike apart.
            let name = screen.localizedName.replacingOccurrences(of: #" \(\d+\)$"#, with: "", options: .regularExpression)
            return device.name.localizedCaseInsensitiveContains(name)
        case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeThunderbolt:
            guard let speaker = usbPort(of: device), let display = port(ofDisplaySerial: CGDisplaySerialNumber(number))
            else { return false }
            return speaker == display
        default:
            return false
        }
    }

    /// The Mac port a USB audio device is plugged into, as the `N` of its `apciecN` controller.
    /// Core Audio's UID for USB audio ends "…:<locationID hex>:<n>".
    private static func usbPort(of device: Device) -> Int? {
        let parts = device.uid.split(separator: ":")
        guard parts.count >= 2, let location = Int(parts[parts.count - 2], radix: 16) else { return nil }
        return first(matching: "IOUSBHostDevice", where: { entry in
            (IORegistryEntryCreateCFProperty(entry, "locationID" as CFString, nil, 0)?.takeRetainedValue() as? Int) == location
        }, ancestorPrefix: "apciec")
    }

    /// The Mac port a display is connected to, as the `N` of its `hpmN` port controller.
    private static func port(ofDisplaySerial serial: UInt32) -> Int? {
        guard serial != 0 else { return nil }
        return first(matching: "IOPortTransportStateDisplayPort", where: { entry in
            (IORegistryEntryCreateCFProperty(entry, "SerialNumber" as CFString, nil, 0)?.takeRetainedValue() as? Int) == Int(serial)
        }, ancestorPrefix: "hpm")
    }

    /// Finds the first service of `className` passing `test`, then walks up the service plane to
    /// the ancestor named `<prefix><digits>` and returns the digits.
    private static func first(matching className: String, where test: (io_registry_entry_t) -> Bool,
                              ancestorPrefix prefix: String) -> Int? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard test(entry) else { continue }
            var current = entry
            IOObjectRetain(current)
            while true {
                var name = [CChar](repeating: 0, count: 128)
                IORegistryEntryGetName(current, &name)
                let text = String(cString: name)
                if text.hasPrefix(prefix), let n = Int(text.dropFirst(prefix.count)) {
                    IOObjectRelease(current)
                    return n
                }
                var parent: io_registry_entry_t = 0
                let found = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS
                IOObjectRelease(current)
                guard found else { break }
                current = parent
            }
        }
        return nil
    }
}

/// Cross-fades StarPlayrX's own sound from one display's speakers to another's with one player.
/// The app's output is tapped (Core Audio process tap, muted while tapped) into a private
/// aggregate device holding just the two speakers in the move; an IO proc copies the tapped
/// samples to both, each with its own software gain. The speakers' volume is never touched.
/// Gone again as soon as the fade ends: the player then plays straight to the new speakers.
@available(macOS 14.2, *)
final class SpeakerCrossfade {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    /// [old gain, new gain, loudest sample heard]: written here, read on the audio thread.
    private let shared = UnsafeMutablePointer<Float>.allocate(capacity: 3)

    init?(from old: String, to new: String) {
        shared.initialize(repeating: 0, count: 3)
        shared[0] = 1
        var pid = getpid()
        var process = AudioObjectID(kAudioObjectUnknown)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                         UInt32(MemoryLayout<pid_t>.size), &pid, &size, &process) == noErr,
              process != kAudioObjectUnknown else { stop(); return nil }
        let tap = CATapDescription(stereoMixdownOfProcesses: [process])
        tap.uuid = UUID()
        tap.muteBehavior = .mutedWhenTapped
        tap.isPrivate = true
        guard AudioHardwareCreateProcessTap(tap, &tapID) == noErr else { stop(); return nil }
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "StarPlayrX Crossfade",
            kAudioAggregateDeviceUIDKey: "com.starplayrx.crossfade.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: new,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: old, kAudioSubDeviceDriftCompensationKey: true],
                [kAudioSubDeviceUIDKey: new],
            ],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tap.uuid.uuidString, kAudioSubTapDriftCompensationKey: true],
            ],
            kAudioAggregateDeviceTapAutoStartKey: true,
        ]
        guard AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID) == noErr
        else { stop(); return nil }
        // The output buffers come one per stream, the old speakers' streams first.
        let oldStreams = Self.outputStreams(of: old)
        let shared = shared
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, input, _, output, _ in
            let outs = UnsafeMutableAudioBufferListPointer(output)
            let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            // The tap's stream comes after any of the speakers' own input streams.
            guard let source = ins.last, let samples = source.mData?.assumingMemoryBound(to: Float.self) else {
                for buffer in outs { if let d = buffer.mData { memset(d, 0, Int(buffer.mDataByteSize)) } }
                return
            }
            let sourceChannels = max(1, Int(source.mNumberChannels))
            let frames = Int(source.mDataByteSize) / (MemoryLayout<Float>.size * sourceChannels)
            var loudest = shared[2]
            for i in 0..<(frames * sourceChannels) { loudest = max(loudest, abs(samples[i])) }
            shared[2] = loudest
            for (index, buffer) in outs.enumerated() {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let channels = max(1, Int(buffer.mNumberChannels))
                let capacity = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
                let gain = index < oldStreams ? shared[0] : shared[1]
                let n = min(frames, capacity)
                for frame in 0..<n {
                    for channel in 0..<channels {
                        data[frame * channels + channel] = samples[frame * sourceChannels + channel % sourceChannels] * gain
                    }
                }
                for i in (n * channels)..<(capacity * channels) { data[i] = 0 }
            }

        }
        guard status == noErr, let procID, AudioDeviceStart(aggregateID, procID) == noErr else { stop(); return nil }
    }

    /// Software gain for the old and the new speakers, 0...1.
    func set(old: Float, new: Float) {
        shared[0] = old
        shared[1] = new
    }

    /// Whether any sound has come through the tap yet. It stays silent if the system's audio
    /// recording permission was refused, and then the fade must not be used.
    var heardSound: Bool { shared[2] > 0 }

    /// Tears everything down; the player is unmuted and plays to the system output again.
    func stop() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            self.procID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    deinit {
        stop()
        shared.deallocate()
    }

    private static func outputStreams(of uid: String) -> Int {
        var id = AudioObjectID(kAudioObjectUnknown)
        var cfUID = uid as CFString
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        _ = withUnsafeMutablePointer(to: &cfUID) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), $0, &size, &id)
        }
        var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                 mScope: kAudioObjectPropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var bytes: UInt32 = 0
        guard id != kAudioObjectUnknown, AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &bytes) == noErr
        else { return 1 }
        return max(1, Int(bytes) / MemoryLayout<AudioStreamID>.size)
    }
}
