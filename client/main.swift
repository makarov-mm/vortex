import AppKit
import MetalKit

// MTKView subclass that forwards key presses (for live tuning).
final class TunableView: MTKView {
    var onKey: ((String) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if let s = event.charactersIgnoringModifiers { onKey?(s) }
    }
}

// ---- Metal device ----------------------------------------------------------
guard let device = MTLCreateSystemDefaultDevice() else {
    fatalError("no Metal device")
}

// ---- app + window ----------------------------------------------------------
let app = NSApplication.shared
app.setActivationPolicy(.regular)

let frame = NSRect(x: 0, y: 0, width: 1000, height: 1000)
let window = NSWindow(
    contentRect: frame,
    styleMask: [.titled, .closable, .resizable, .miniaturizable],
    backing: .buffered,
    defer: false
)
window.title = "Vortex Field"
window.center()

let mtkView = TunableView(frame: frame, device: device)
mtkView.colorPixelFormat = .bgra8Unorm
mtkView.framebufferOnly = true
mtkView.preferredFramesPerSecond = 60
mtkView.clearColor = MTLClearColorMake(0, 0, 0, 1)

let renderer: Renderer
do {
    renderer = try Renderer(view: mtkView, device: device)
} catch {
    fatalError("renderer init failed: \(error)")
}

// live tuning: window title shows current values
renderer.onStatus = { [weak window] s in window?.title = "Vortex Field — \(s)" }
mtkView.onKey = { renderer.handleKey($0) }

// prime the trail texture at the initial drawable size
renderer.mtkView(mtkView, drawableSizeWillChange: mtkView.drawableSize)
mtkView.delegate = renderer

window.contentView = mtkView
window.makeKeyAndOrderFront(nil)
window.makeFirstResponder(mtkView)
renderer.emitStatus()

// ---- minimal menu so Cmd-Q works -------------------------------------------
let mainMenu = NSMenu()
let appItem = NSMenuItem()
mainMenu.addItem(appItem)
let appMenu = NSMenu()
appMenu.addItem(withTitle: "Quit Vortex Field", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appItem.submenu = appMenu
app.mainMenu = mainMenu

// ---- connect to the Elixir backend -----------------------------------------
let host = ProcessInfo.processInfo.environment["VORTEX_HOST"] ?? "127.0.0.1"
let port = UInt16(ProcessInfo.processInfo.environment["VORTEX_PORT"] ?? "4000") ?? 4000

let client = FieldClient(host: host, port: port) { w, h, field, vcount, vdata in
    renderer.updateField(w: w, h: h, field: field, vortexCount: vcount, vortexBytes: vdata)
}
client.start()

// floating control panel (kept alive by this strong reference)
let controls = ControlPanel(renderer: renderer, client: client, view: mtkView)
controls.show(near: window)

print("""
    controls:  [ ]  trail length      - =  speed
               , .  point size        1-4  particle count (250k/500k/750k/1M)
               r    reset trail        Cmd-Q  quit
    """)

app.activate(ignoringOtherApps: true)
app.run()
