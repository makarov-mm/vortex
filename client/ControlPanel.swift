import AppKit
import MetalKit

/// Closure-backed target so each control can carry its own action.
final class ActionTarget: NSObject {
    private let cb: (NSControl) -> Void
    init(_ cb: @escaping (NSControl) -> Void) { self.cb = cb }
    @objc func fire(_ sender: NSControl) { cb(sender) }
}

/// A floating panel of sliders/buttons. Client-side "look" controls apply
/// instantly to the renderer; "simulation" controls are sent to the Elixir
/// backend over the command channel.
final class ControlPanel {
    let panel: NSPanel
    private let stack = NSStackView()
    private var targets: [ActionTarget] = []   // keep control targets alive

    init(renderer: Renderer, client: FieldClient, view: MTKView) {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 264, height: 620),
            styleMask: [.titled, .closable, .utilityWindow, .resizable],
            backing: .buffered, defer: false
        )
        panel.title = "Controls"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor)
        ])
        panel.contentView = content

        // ---- look (client-side, instant) ----
        section("Look — applied instantly")
        slider("Speed", 0.0, 2.0, Double(renderer.currentSpeed), continuous: true,
               fmt: { String(format: "%.2f", $0) }) { renderer.setSpeed(Float($0)) }
        slider("Trail fade", 0.01, 0.30, Double(renderer.currentFade), continuous: true,
               fmt: { String(format: "%.3f", $0) }) { renderer.setFade(Float($0)) }
        slider("Point size", 0.5, 4.0, Double(renderer.currentPointSize), continuous: true,
               fmt: { String(format: "%.1f", $0) }) { renderer.setPointSize(Float($0)) }
        slider("Particles", 250_000, 1_500_000, Double(renderer.currentParticleCount),
               continuous: false, fmt: { "\(Int($0 / 1000))k" }) {
            renderer.setParticles(Int(($0 / 50_000).rounded()) * 50_000)
        }

        // ---- simulation (server-side, via command channel) ----
        section("Simulation — sent to the backend")
        slider("Vortices", 1, 120, 18, continuous: false,
               fmt: { "\(Int($0.rounded()))" }) { client.setVortexCount(Int($0.rounded())) }
        slider("Grid", 16, 160, 64, continuous: false,
               fmt: { let n = Int($0.rounded()); return "\(n)×\(n)" }) {
            let n = Int($0.rounded()); client.setGrid(n, n)
        }
        slider("Circulation", 0.6, 3.0, 1.6, continuous: false,
               fmt: { String(format: "%.1f", $0) }) { client.setGamma(0.3, Float($0)) }

        // ---- actions ----
        section("Actions")
        button("Reseed vortices") { client.reseedVortices() }
        button("Reset particles") { renderer.resetParticles() }
        button("Clear trail") { renderer.resetTrail() }
        button("Pause / resume") { view.isPaused.toggle() }
    }

    func show(near main: NSWindow) {
        let f = main.frame
        panel.setFrameOrigin(NSPoint(x: f.maxX + 12, y: f.maxY - panel.frame.height))
        panel.orderFront(nil)
    }

    // ---- builders ----------------------------------------------------------
    private func section(_ title: String) {
        let l = NSTextField(labelWithString: title.uppercased())
        l.font = .systemFont(ofSize: 10, weight: .semibold)
        l.textColor = .secondaryLabelColor
        if !stack.arrangedSubviews.isEmpty {
            stack.setCustomSpacing(16, after: stack.arrangedSubviews.last!)
        }
        stack.addArrangedSubview(l)
    }

    private func slider(_ title: String, _ lo: Double, _ hi: Double, _ value: Double,
                        continuous: Bool, fmt: @escaping (Double) -> String,
                        apply: @escaping (Double) -> Void) {
        let label = NSTextField(labelWithString: "\(title): \(fmt(value))")
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)

        let s = NSSlider(value: value, minValue: lo, maxValue: hi, target: nil, action: nil)
        s.isContinuous = continuous
        s.translatesAutoresizingMaskIntoConstraints = false
        s.widthAnchor.constraint(equalToConstant: 224).isActive = true

        let target = ActionTarget { c in
            let v = (c as! NSSlider).doubleValue
            label.stringValue = "\(title): \(fmt(v))"
            apply(v)
        }
        s.target = target
        s.action = #selector(ActionTarget.fire(_:))
        targets.append(target)

        let row = NSStackView(views: [label, s])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 2
        stack.addArrangedSubview(row)
    }

    private func button(_ title: String, action: @escaping () -> Void) {
        let target = ActionTarget { _ in action() }
        targets.append(target)
        let b = NSButton(title: title, target: target, action: #selector(ActionTarget.fire(_:)))
        b.bezelStyle = .rounded
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 224).isActive = true
        stack.addArrangedSubview(b)
    }
}
