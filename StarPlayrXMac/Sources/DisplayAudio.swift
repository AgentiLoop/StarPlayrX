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

    /// Makes the device with this UID the Mac's sound output, if it isn't already.
    static func makeSystemOutput(_ uid: String) {
        guard var id = outputDevices().first(where: { $0.uid == uid })?.id, id != systemOutput() else { return }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                   UInt32(MemoryLayout<AudioObjectID>.size), &id)
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
