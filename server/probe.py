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
    w, h, idx, vc, _res = struct.unpack("<HHIHH", payload[:12])
    fbytes = w * h * 2 * 4
    field = struct.unpack("<%df" % (w * h * 2), payload[12:12 + fbytes])
    vraw = payload[12 + fbytes:12 + fbytes + vc * 12]
    vortices = [struct.unpack("<fff", vraw[k*12:k*12+12]) for k in range(vc)]
    return w, h, idx, field, vortices

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
    vlast = []
    for f in range(90):  # ~3s at 30fps
        w, h, idx, field, vortices = read_frame(s)
        idxs.append(idx)
        last = (w, h, idx, field)
        vlast = vortices
    w, h, idx, field = last
    speeds = [math.hypot(field[2*c], field[2*c+1]) for c in range(w*h)]
    art, spmax = quiver(w, h, field)
    print(f"\ngrid {w}x{h}   frames read: {len(idxs)}   "
          f"frame_index {idxs[0]}..{idxs[-1]} (Δ={idxs[-1]-idxs[0]})")
    pos = sum(1 for v in vlast if v[2] > 0); neg = len(vlast) - pos
    print(f"speed  min={min(speeds):.3f}  mean={sum(speeds)/len(speeds):.3f}  max={max(speeds):.3f}")
    print(f"vortices: {len(vlast)}  (+{pos} ccw / -{neg} cw)  e.g. {tuple(round(c,3) for c in vlast[0]) if vlast else None}\n")
    print(art)
    s.close()

if __name__ == "__main__":
    main()
