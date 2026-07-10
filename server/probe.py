import socket, struct, math, sys

HOST, PORT = "127.0.0.1", 4000

def recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("peer closed")
        buf += chunk
    return buf

def read_frame(sock):
    # gen_tcp {packet,4} prepends a 4-byte BIG-endian length
    (length,) = struct.unpack(">I", recv_exact(sock, 4))
    payload = recv_exact(sock, length)
    w, h, idx = struct.unpack("<HHI", payload[:8])
    body = payload[8:]
    assert len(body) == w * h * 2 * 4, (len(body), w * h * 2 * 4)
    field = struct.unpack("<%df" % (w * h * 2), body)
    return w, h, idx, field

ARROWS = "→↗↑↖←↙↓↘"
def arrow(u, v):
    if u * u + v * v < 1e-9:
        return "·"
    a = math.atan2(v, u)  # -pi..pi
    k = int(round(a / (math.pi / 4))) % 8
    return ARROWS[k]

def quiver(w, h, field, cols=28, rows=14):
    out = []
    spmax = 0.0
    for ry in range(rows):
        line = []
        gy = int((ry + 0.5) / rows * h)
        for rx in range(cols):
            gx = int((rx + 0.5) / cols * w)
            c = gy * w + gx
            u = field[2 * c]; v = field[2 * c + 1]
            spmax = max(spmax, math.hypot(u, v))
            line.append(arrow(u, v))
        out.append("".join(line))
    # top row = high y; flip so +y is up on screen
    return "\n".join(reversed(out)), spmax

def main():
    s = socket.create_connection((HOST, PORT), timeout=5)
    print(f"connected to {HOST}:{PORT}")
    idxs = []
    last = None
    for f in range(90):  # ~3s at 30fps
        w, h, idx, field = read_frame(s)
        idxs.append(idx)
        last = (w, h, idx, field)
    w, h, idx, field = last
    speeds = [math.hypot(field[2*c], field[2*c+1]) for c in range(w*h)]
    art, spmax = quiver(w, h, field)
    print(f"\ngrid {w}x{h}   frames read: {len(idxs)}   "
          f"frame_index {idxs[0]}..{idxs[-1]} (Δ={idxs[-1]-idxs[0]})")
    print(f"speed  min={min(speeds):.3f}  mean={sum(speeds)/len(speeds):.3f}  max={max(speeds):.3f}\n")
    print(art)
    s.close()

if __name__ == "__main__":
    main()
