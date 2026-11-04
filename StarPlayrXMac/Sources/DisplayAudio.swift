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
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else { return nil }
        let map = speakers()
        guard let now = systemOutputUID(), map[now] != nil else { return nil }
        return map.first { $0.value == number }?.key
    }

    /// Which display each display speaker belongs to (speaker UID → display). Working it out walks
    /// the IOKit registry (~50 ms), far too slow for every move of the panel, so it is kept until
    /// a display or an audio device comes or goes.
    private static var cache: [String: CGDirectDisplayID]?
    private static var watching = false

    private static func speakers() -> [String: CGDirectDisplayID] {
        if let cache { return cache }
        if !watching {
            watching = true
            NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                   object: nil, queue: .main) { _ in cache = nil }
            var devices = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devices, .main) { _, _ in
                cache = nil
            }
        }
        let outputs = outputDevices()
        var map = [String: CGDirectDisplayID]()
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  let speaker = outputs.first(where: { matches($0, screen: screen, among: outputs) }) else { continue }
            map[speaker.uid] = number
        }
        cache = map
        return map
    }

    /// The Core Audio UID of the Mac's sound output right now.
    static func systemOutputUID() -> String? {
        let id = systemOutput()
        return outputDevices().first(where: { $0.id == id })?.uid
    }

    /// Starts the speakers `uid` playing silence, so they are already running when the player
    /// switches to them: a device that has to start up first leaves a gap in the sound. Call the
    /// returned closure to stop the silence once the player is on them.
    static func warmUp(_ uid: String) -> () -> Void {
        guard let id = outputDevices().first(where: { $0.uid == uid })?.id else { return {} }
        var proc: AudioDeviceIOProcID?
        let made = AudioDeviceCreateIOProcIDWithBlock(&proc, id, nil) { _, _, _, output, _ in
            for buffer in UnsafeMutableAudioBufferListPointer(output) {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
        }
        guard made == noErr, let proc, AudioDeviceStart(id, proc) == noErr else { return {} }
        return {
            AudioDeviceStop(id, proc)
            AudioDeviceDestroyIOProcID(id, proc)
        }
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
