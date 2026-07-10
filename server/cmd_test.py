import socket, struct, time

HOST, PORT = "127.0.0.1", 4000

def recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        c = sock.recv(n - len(buf))
        if not c: raise ConnectionError("closed")
        buf += c
    return buf

def read_frame(sock):
    (length,) = struct.unpack(">I", recv_exact(sock, 4))   # {packet,4} BE length
    payload = recv_exact(sock, length)
    w, h, idx = struct.unpack("<HHI", payload[:8])
    return w, h, idx

def send_cmd(sock, payload: bytes):
    # mirror {packet,4}: prepend 4-byte BE length
    sock.sendall(struct.pack(">I", len(payload)) + payload)

def wait_grid(sock, want, tries=90):
    for _ in range(tries):
        w, h, _ = read_frame(sock)
        if (w, h) == want:
            return True
    return False

def result(label, ok):
    print(("  PASS  " if ok else "  FAIL  ") + label)

def main():
    s = socket.create_connection((HOST, PORT), timeout=5)
    w, h, _ = read_frame(s)
    result(f"baseline grid {w}x{h}", (w, h) == (64, 64))

    # 0x03: set grid 96x72
    send_cmd(s, bytes([0x03]) + struct.pack("<HH", 96, 72))
    result("set_grid 96x72 reflected in stream", wait_grid(s, (96, 72)))

    # 0x02: set vortex count (not visible in header, must not break the stream)
    send_cmd(s, bytes([0x02]) + struct.pack("<H", 45))
    # 0x01: reseed ; 0x04: gamma
    send_cmd(s, bytes([0x01]))
    send_cmd(s, bytes([0x04]) + struct.pack("<ff", 0.8, 2.2))
    # malformed command must be ignored, not crash the server
    send_cmd(s, bytes([0x7F, 0x00, 0x00]))

    ok = True
    last = None
    for _ in range(30):
        w, h, idx = read_frame(s)
        if last is not None and idx != last + 1:
            ok = False
        last = idx
    result("stream healthy + contiguous after commands", ok and (w, h) == (96, 72))

    # shrink grid back, with clamp test
    send_cmd(s, bytes([0x03]) + struct.pack("<HH", 4, 4))   # -> clamps to 16x16
    result("grid clamps to 16x16", wait_grid(s, (16, 16)))

    s.close()

if __name__ == "__main__":
    main()
