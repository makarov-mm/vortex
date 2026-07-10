import Foundation
import Network

/// Reads velocity-field frames from the Elixir backend.
///
/// Wire format (see backend README): the socket runs `{packet, 4}`, so each
/// frame is prefixed by a 4-byte BIG-endian length. The payload it describes
/// is little-endian: `uint16 w, uint16 h, uint32 frame_index, float32 field[w*h*2]`.
final class FieldClient {
    private let conn: NWConnection
    private let onFrame: (_ w: Int, _ h: Int, _ field: Data) -> Void
    private let queue = DispatchQueue(label: "vortex.field.client", qos: .userInteractive)

    init(host: String, port: UInt16,
         onFrame: @escaping (_ w: Int, _ h: Int, _ field: Data) -> Void) {
        self.onFrame = onFrame
        self.conn = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
    }

    func start() {
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:        print("[net] connected")
            case .waiting(let e): print("[net] waiting: \(e)")
            case .failed(let e):  print("[net] failed: \(e)")
            case .cancelled:      print("[net] cancelled")
            default: break
            }
        }
        conn.start(queue: queue)
        readLength()
    }

    // read exactly `n` bytes, then hand them to `done`
    private func readExactly(_ n: Int, _ done: @escaping (Data) -> Void) {
        conn.receive(minimumIncompleteLength: n, maximumLength: n) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                print("[net] receive error: \(error)")
                return
            }
            guard let data, data.count == n else {
                if isComplete { print("[net] peer closed") }
                return
            }
            done(data)
        }
    }

    private func readLength() {
        readExactly(4) { [weak self] data in
            let b = [UInt8](data)
            let n = (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
            self?.readPayload(Int(n))
        }
    }

    private func readPayload(_ n: Int) {
        readExactly(n) { [weak self] data in
            guard let self else { return }
            let b = [UInt8](data)
            let w = Int(b[0]) | (Int(b[1]) << 8)
            let h = Int(b[2]) | (Int(b[3]) << 8)
            // b[4..7] = frame_index (LE) — not needed by the renderer
            let expected = w * h * 2 * MemoryLayout<Float>.size
            if data.count - 8 == expected {
                let field = data.subdata(in: 8..<data.count)
                self.onFrame(w, h, field)
            } else {
                print("[net] bad frame: got \(data.count - 8) field bytes, expected \(expected)")
            }
            self.readLength()   // next frame
        }
    }

    // ---- upstream commands (client -> server) ------------------------------
    // Mirrors {packet,4}: each command is prefixed with a 4-byte BE length.

    func sendCommand(_ payload: [UInt8]) {
        let n = UInt32(payload.count).bigEndian
        var frame = withUnsafeBytes(of: n) { Array($0) }   // 4-byte BE length
        frame.append(contentsOf: payload)
        conn.send(content: Data(frame), completion: .contentProcessed { _ in })
    }

    func reseedVortices() { sendCommand([0x01]) }
    func setVortexCount(_ n: Int) { sendCommand([0x02] + u16le(n)) }
    func setGrid(_ w: Int, _ h: Int) { sendCommand([0x03] + u16le(w) + u16le(h)) }
    func setGamma(_ mn: Float, _ mx: Float) { sendCommand([0x04] + f32le(mn) + f32le(mx)) }

    private func u16le(_ v: Int) -> [UInt8] {
        let u = UInt16(clamping: v)
        return [UInt8(u & 0xff), UInt8(u >> 8)]
    }
    private func f32le(_ v: Float) -> [UInt8] {
        let x = v.bitPattern.littleEndian
        return withUnsafeBytes(of: x) { Array($0) }
    }

    func cancel() { conn.cancel() }
}
