// OpalMini — minimal menu-bar controller for the Opal C1 (standalone UVC mode, 03e7:f63d).
// Talks standard UVC class requests through IOKit (no root needed, unlike libusb on macOS ≥12.3).
// Also logs every Movidius (03e7:*) attach/detach to ~/Library/Logs/OpalMini.log to diagnose dropouts.
import SwiftUI
import IOKit
import IOKit.usb
import ServiceManagement
import AVFoundation

let VID = 0x03E7, PID_UVC = 0xF63D
let VC_IF: UInt16 = 1, CT: UInt16 = 1, PU: UInt16 = 3  // from the camera's VideoControl descriptors

// IOKit UUID macros aren't bridged to Swift.
let kIOUSBDeviceUserClientTypeID = CFUUIDGetConstantUUIDWithBytes(nil, 0x9d,0xc7,0xb7,0x80,0x9e,0xc0,0x11,0xD4,0xa5,0x4f,0x00,0x0a,0x27,0x05,0x28,0x61)
let kIOCFPlugInInterfaceID = CFUUIDGetConstantUUIDWithBytes(nil, 0xC2,0x44,0xE8,0x58,0x10,0x9C,0x11,0xD4,0x91,0xD4,0x00,0x50,0xE4,0xC6,0x42,0x6F)
let kIOUSBDeviceInterfaceID = CFUUIDGetConstantUUIDWithBytes(nil, 0x5c,0x81,0x87,0xd0,0x9e,0xf3,0x11,0xD4,0x8b,0x45,0x00,0x0a,0x27,0x05,0x28,0x61)

enum Kind { case slider, toggle, aeMode, powerline }
struct Spec { let name: String; let unit: UInt16; let sel: UInt8; let size: Int; let kind: Kind; var autoOf: String? = nil; var signed = false; var advanced = false }

let SPECS: [Spec] = [
    Spec(name: "Brightness", unit: PU, sel: 0x02, size: 2, kind: .slider, signed: true),
    Spec(name: "Contrast", unit: PU, sel: 0x03, size: 2, kind: .slider),
    Spec(name: "Saturation", unit: PU, sel: 0x07, size: 2, kind: .slider),
    Spec(name: "Sharpness", unit: PU, sel: 0x08, size: 2, kind: .slider),
    Spec(name: "Anti-flicker", unit: PU, sel: 0x05, size: 1, kind: .powerline),  // 50 Hz in Europe kills LED/neon banding
    Spec(name: "Autofocus", unit: CT, sel: 0x08, size: 1, kind: .toggle),
    Spec(name: "Focus", unit: CT, sel: 0x06, size: 2, kind: .slider, autoOf: "Autofocus", advanced: true),
    Spec(name: "Auto exposure", unit: CT, sel: 0x02, size: 1, kind: .aeMode, advanced: true),
    Spec(name: "Exposure", unit: CT, sel: 0x04, size: 4, kind: .slider, autoOf: "Auto exposure", advanced: true),
    Spec(name: "Gain", unit: PU, sel: 0x04, size: 2, kind: .slider, autoOf: "Auto exposure", advanced: true),
    Spec(name: "Auto white balance", unit: PU, sel: 0x0B, size: 1, kind: .toggle, advanced: true),
    Spec(name: "White balance", unit: PU, sel: 0x0A, size: 2, kind: .slider, autoOf: "Auto white balance", advanced: true),
    Spec(name: "Hue", unit: PU, sel: 0x06, size: 2, kind: .slider, signed: true, advanced: true),
    Spec(name: "Backlight comp.", unit: PU, sel: 0x01, size: 2, kind: .slider, advanced: true),
]

// MARK: - UVC over IOKit

final class UVC {
    private(set) var firmware = "?"
    private let dev: UnsafeMutablePointer<UnsafeMutablePointer<IOUSBDeviceInterface>?>

    init?() {
        let m = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary
        m["idVendor"] = VID; m["idProduct"] = PID_UVC
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, m)
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        let bcd = IORegistryEntryCreateCFProperty(svc, "bcdDevice" as CFString, nil, 0)?.takeRetainedValue() as? Int ?? 0
        firmware = String(format: "%x.%02x", bcd >> 8, bcd & 0xff)
        var plug: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var score: Int32 = 0
        guard IOCreatePlugInInterfaceForService(svc, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plug, &score) == KERN_SUCCESS,
              let plug else { return nil }
        defer { _ = plug.pointee?.pointee.Release(plug) }
        var raw: UnsafeMutableRawPointer?
        _ = withUnsafeMutablePointer(to: &raw) { plug.pointee!.pointee.QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), $0) }
        guard let raw else { return nil }
        dev = raw.assumingMemoryBound(to: UnsafeMutablePointer<IOUSBDeviceInterface>?.self)
    }
    deinit { _ = dev.pointee?.pointee.Release(dev) }

    private func request(_ type: UInt8, _ req: UInt8, _ s: Spec, _ data: inout [UInt8]) -> Bool {
        var r = IOUSBDevRequestTO(bmRequestType: type, bRequest: req, wValue: UInt16(s.sel) << 8, wIndex: s.unit << 8 | VC_IF,
                                  wLength: UInt16(s.size), pData: nil, wLenDone: 0, noDataTimeout: 500, completionTimeout: 500)
        return data.withUnsafeMutableBytes { buf in
            r.pData = buf.baseAddress
            return dev.pointee!.pointee.DeviceRequestTO(dev, &r) == KERN_SUCCESS
        }
    }

    // req: 0x81 cur, 0x82 min, 0x83 max, 0x87 def
    func get(_ s: Spec, _ req: UInt8 = 0x81) -> Int? {
        var b = [UInt8](repeating: 0, count: s.size)
        guard request(0xA1, req, s, &b) else { return nil }
        let u = b.enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        return s.signed && s.size == 2 ? Int(Int16(truncatingIfNeeded: u)) : u
    }

    @discardableResult func set(_ s: Spec, _ v: Int) -> Bool {
        var b = (0..<s.size).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) }
        return request(0x21, 0x01, s, &b)
    }
}

// MARK: - Model

struct Control: Identifiable { let spec: Spec; var min = 0, max = 1, def = 0, value = 0; var id: String { spec.name } }

@MainActor final class Model: ObservableObject {
    @Published var controls: [Control] = []
    @Published var connected = false
    @Published var firmware = "?"
    let bootloader = (try? String(contentsOf: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/OpalMini/bootloader.txt"), encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
    private var uvc: UVC?
    private let logger = USBLogger()
    // User choices survive replugs (the camera forgets them on power loss). Default: 50 Hz anti-flicker.
    private var saved: [String: Int] {
        get { UserDefaults.standard.dictionary(forKey: "saved") as? [String: Int] ?? ["Anti-flicker": 1] }
        set { UserDefaults.standard.set(newValue, forKey: "saved") }
    }

    init() {
        logger.onChange = { [weak self] in
            // the firmware needs a moment after enumeration before it answers control requests
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.refresh(apply: true) }
        }
        logger.start()
        refresh(apply: true)
    }

    func refresh(apply: Bool = false) {
        uvc = UVC()
        connected = uvc != nil
        firmware = uvc?.firmware ?? "?"
        guard let uvc else { controls = []; return }
        if apply {
            let ok = SPECS.filter { s in saved[s.name].map { uvc.set(s, $0) } ?? false }.map(\.name)
            USBLogger.log("applied \(ok)")
        }
        controls = SPECS.compactMap { s in
            guard let cur = uvc.get(s) else { return nil }  // firmware doesn't support it → hide
            return Control(spec: s, min: uvc.get(s, 0x82) ?? 0, max: uvc.get(s, 0x83) ?? 1, def: uvc.get(s, 0x87) ?? cur,
                           value: saved[s.name] ?? cur)  // some controls (anti-flicker, sharpness) read back 0 after SET
        }
    }

    func set(_ name: String, _ v: Int) {
        guard let i = controls.firstIndex(where: { $0.id == name }) else { return }
        controls[i].value = v
        saved[name] = v
        if uvc?.set(controls[i].spec, v) != true { refresh() }
    }

    func isAuto(_ name: String?) -> Bool {
        guard let name, let c = controls.first(where: { $0.id == name }) else { return false }
        return c.spec.kind == .aeMode ? c.value != 1 : c.value != 0
    }

    func resetAll() {
        for c in controls { set(c.id, c.def) }
        saved = [:]
    }
}

// MARK: - Dropout logger

final class USBLogger {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/OpalMini.log")
    private var iters: [io_iterator_t] = []
    var onChange: () -> Void = {}

    static func log(_ s: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
        else { try? line.write(to: url, atomically: true, encoding: .utf8) }
    }

    func start() {
        let port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, .main)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        for (type, label) in [(kIOFirstMatchNotification, "ATTACH"), (kIOTerminatedNotification, "DETACH")] {
            let m = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary
            m["idVendor"] = VID
            var it: io_iterator_t = 0
            let cb: IOServiceMatchingCallback = { ctx, it in
                let me = Unmanaged<USBLogger>.fromOpaque(ctx!).takeUnretainedValue()
                me.drain(it, label: me.labels[it] ?? "?")
            }
            IOServiceAddMatchingNotification(port, type, m, cb, ctx, &it)
            labels[it] = label
            drain(it, label: label, quiet: true)  // arm the iterator
            iters.append(it)
        }
    }

    private var labels: [io_iterator_t: String] = [:]

    private func drain(_ it: io_iterator_t, label: String, quiet: Bool = false) {
        while case let s = IOIteratorNext(it), s != 0 {
            let pid = IORegistryEntryCreateCFProperty(s, "idProduct" as CFString, nil, 0)?.takeRetainedValue() as? Int ?? 0
            // f63d = flashed UVC app, f63c = bootloader, f63b = booted by host, 2485 = ROM (no/broken flash)
            if !quiet { USBLogger.log("\(label) 03e7:\(String(pid, radix: 16))") }
            IOObjectRelease(s)
        }
        if !quiet { onChange() }
    }
}

// Hardware check: OpalMini.app/Contents/MacOS/OpalMini --selftest
func selftest() -> Never {
    guard let uvc = UVC() else { print("FAIL: camera not found"); exit(1) }
    for s in SPECS {
        print(s.name.padding(toLength: 20, withPad: " ", startingAt: 0),
              uvc.get(s).map { "cur=\($0) min=\(uvc.get(s, 0x82) ?? -1) max=\(uvc.get(s, 0x83) ?? -1) def=\(uvc.get(s, 0x87) ?? -1)" } ?? "unsupported")
    }
    let b = SPECS.first { $0.name == "Saturation" }!
    let orig = uvc.get(b)!, probe = orig == 100 ? 101 : 100
    assert(uvc.set(b, probe) && uvc.get(b) == probe, "set/readback failed")
    uvc.set(b, orig)
    assert(uvc.get(b) == orig, "restore failed")
    print("OK: set/readback/restore")
    exit(0)
}

// MARK: - UI

struct ControlRow: View {
    let c: Control
    @ObservedObject var model: Model
    var body: some View {
        switch c.spec.kind {
        case .toggle:
            Toggle(c.id, isOn: Binding(get: { c.value != 0 }, set: { model.set(c.id, $0 ? 1 : 0) }))
        case .aeMode:  // UVC bitmap: 1 manual, 2 auto, 4 shutter prio, 8 aperture prio
            Toggle(c.id, isOn: Binding(get: { c.value != 1 }, set: { model.set(c.id, $0 ? (c.def == 1 ? 8 : c.def) : 1) }))
        case .powerline:
            Picker(c.id, selection: Binding(get: { c.value }, set: { model.set(c.id, $0) })) {
                Text("Off").tag(0); Text("50 Hz").tag(1); Text("60 Hz").tag(2)
            }.pickerStyle(.segmented)
        case .slider:
            VStack(alignment: .leading, spacing: 2) {
                HStack { Text(c.id); Spacer(); Text("\(c.value)").monospacedDigit().foregroundStyle(.secondary) }
                Slider(value: Binding(get: { Double(c.value) }, set: { model.set(c.id, Int($0)) }),
                       in: Double(c.min)...Double(max(c.max, c.min + 1)))
                    .disabled(model.isAuto(c.spec.autoOf))
            }
        }
    }
}

// Live preview, only running while the menu is open.
final class PreviewView: NSView {
    private let session = AVCaptureSession()
    private let layerP: AVCaptureVideoPreviewLayer

    override init(frame: NSRect) {
        layerP = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: frame)
        layerP.videoGravity = .resizeAspectFill
        layer = layerP  // layer-hosting: assign the layer before wantsLayer
        wantsLayer = true
        guard let cam = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified)
                .devices.first(where: { $0.localizedName.contains("Opal") }),
              let input = try? AVCaptureDeviceInput(device: cam), session.canAddInput(input) else { return }
        session.addInput(input)
        if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
    }
    required init?(coder: NSCoder) { nil }
    deinit { session.stopRunning() }

    // MenuBarExtra hides its window instead of destroying it: follow visibility so the camera turns off with the menu.
    override func viewDidMoveToWindow() {
        NotificationCenter.default.removeObserver(self)
        guard let window else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(sync), name: NSWindow.didChangeOcclusionStateNotification, object: window)
        sync()
    }
    @objc private func sync() {
        let visible = window?.occlusionState.contains(.visible) == true
        DispatchQueue.global(qos: .userInitiated).async { [session] in
            if visible, !session.isRunning { session.startRunning() }
            if !visible, session.isRunning { session.stopRunning() }
        }
    }
}

struct Preview: NSViewRepresentable {
    func makeNSView(context: Context) -> PreviewView { PreviewView() }
    func updateNSView(_ v: PreviewView, context: Context) {}
}

struct Panel: View {
    @ObservedObject var model: Model
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle().fill(model.connected ? .green : .red).frame(width: 8, height: 8)
                Text(model.connected ? "Opal C1" : "Opal C1 not connected").font(.headline)
                Spacer()
                Button("↻") { model.refresh() }.buttonStyle(.borderless).help("Re-read controls")
            }
            if model.connected {
                Preview().frame(width: 272, height: 153)  // 16:9; NSViewRepresentable has no intrinsic size
.clipShape(RoundedRectangle(cornerRadius: 8))
            }
            ForEach(model.controls.filter { !$0.spec.advanced }) { ControlRow(c: $0, model: model) }
            DisclosureGroup("Advanced") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.controls.filter { $0.spec.advanced }) { ControlRow(c: $0, model: model) }
                }.padding(.top, 6)
            }
            Divider()
            Toggle("Launch at login", isOn: Binding(
                get: { SMAppService.mainApp.status == .enabled },
                set: { on in _ = try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister(); model.objectWillChange.send() }))
            HStack {
                Button("Defaults") { model.resetAll() }.disabled(!model.connected)
                Button("Log") { NSWorkspace.shared.open(USBLogger.url) }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            Text("Firmware \(model.firmware) · Bootloader \(model.bootloader)")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14).frame(width: 300)
        .onAppear { model.refresh() }
    }
}

@main struct OpalMini: App {
    // Created eagerly: a @StateObject inside MenuBarExtra only initializes when the menu is first opened,
    // which would delay settings re-apply and USB logging until then.
    private let model: Model
    init() {
        if CommandLine.arguments.contains("--selftest") { selftest() }
        USBLogger.log("OpalMini started")
        model = Model()
    }
    var body: some Scene {
        MenuBarExtra("Opal", systemImage: "web.camera") { Panel(model: model) }.menuBarExtraStyle(.window)
    }
}
