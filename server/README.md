# vortex_field — Elixir backend

A small Hamiltonian point-vortex system (RK4), rasterised each tick into a
velocity-field grid and streamed over TCP. The Swift + Metal client advects
particles through that field.

Zero external dependencies (stdlib `:gen_tcp`, `Registry`, `Task` only).

## Run

```sh
./run.sh          # compile + start server (tcp/4000)
./run.sh verify   # analytic + wire-format checks
./run.sh probe    # ASCII-quiver probe against a running server
```

Or directly with mix:

```sh
mix run --no-halt
# listening on tcp/4000, 18 vortices, 64x64 grid @ 30 fps
```

Tunables live in `lib/vortex_field/config.ex` (grid size, fps, vortex count,
circulation range, core radius, recycle/spawn radii, lifetime, speed clamp).

## Verify

```sh
mix run --no-start verify.exs   # analytic + wire-format assertions (12 checks)
python3 probe.py                # live probe: prints an ASCII quiver of the field
```

## Wire protocol

TCP, one frame per tick. The socket runs in Erlang `{packet, 4}` mode, so every
frame is prefixed by a **4-byte BIG-endian length** (added/parsed by the framing
layer). The payload it describes is all **little-endian** so the client can copy
the field straight into a Metal texture with no byte-swapping:

```
[ uint32 BE ]  N              # length of the payload that follows
payload (N bytes):
  uint16 LE    w              # grid width   (default 64)
  uint16 LE    h              # grid height  (default 64)
  uint32 LE    frame_index    # monotonic
  uint16 LE    vortex_count   # number of vortex markers after the field
  uint16 LE    reserved       # 0 (keeps the field 4-byte aligned at offset 12)
  float32 LE   field[w*h*2]   # row-major (j outer, i inner), interleaved (u, v)
  float32 LE   vortices[vc*3] # (x, y, gamma_eff) per vortex
```

Header is 12 bytes. The field starts at offset 12; the vortex list starts at
`12 + w*h*2*4`. Cell `(i, j)` holds `(u, v)` at field offset `(j*w + i)*8`. The
grid samples world space `[-domain, domain]²` (default `domain = 1.0`) at cell
centres:

```
x = -domain + (i + 0.5) * (2*domain / w)
y = -domain + (j + 0.5) * (2*domain / h)
```

`+y is up`, `Γ > 0` is counter-clockwise. Field speed is clamped to `max_speed`
(default 6.0). Client-side plan: upload the field as an `RG32Float` texture and
sample it with hardware bilinear filtering when advecting particles.

## Upstream commands (client → server)

The same `{packet, 4}` socket carries commands the other way: the client
prefixes a 4-byte BE length, then a payload whose first byte is the opcode.

```
0x01                                  reseed vortices (fresh positions)
0x02  uint16 le  n                    set vortex count      (clamped 1..200)
0x03  uint16 le  w, uint16 le  h      set streamed grid     (clamped 16..200)
0x04  float32 le mn, float32 le mx    set circulation range
```

Malformed commands are ignored. Grid changes are visible in the very next
frame header, so a client can confirm them without a separate ack.

## Client reader (reference, from probe.py)

1. read 4 bytes, big-endian → `N`
2. read exactly `N` bytes → payload
3. `w, h, frame_index = payload[0..8]` (uint16 LE, uint16 LE, uint32 LE)
4. remaining `w*h*2` float32 LE = the field
