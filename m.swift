import AppKit
import CoreAudio
let app = NSApplication.shared
print("system output:", DisplayAudio.systemOutputUID() ?? "nil")
for d in DisplayAudio.outputDevices() { print("dev", d.name, d.uid, String(d.transport, radix:16), DisplayAudio.usbPort(of: d) as Any) }
for s in NSScreen.screens {
  let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID
  print("screen", s.localizedName, n, CGDisplaySerialNumber(n), CGDisplayIsBuiltin(n), DisplayAudio.port(ofDisplaySerial: CGDisplaySerialNumber(n)) as Any, DisplayAudio.device(for: s) as Any)
}
print(DisplayAudio.speakers())
