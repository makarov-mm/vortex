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
  float32 LE   field[w*h*2]   # row-major (j outer, i inner), interleaved (u, v)
```

Cell `(i, j)` lives at byte offset `8 + (j*w + i)*8` inside the payload and
holds `(u, v)`. The grid samples world space `[-domain, domain]²` (default
`domain = 1.0`) at cell centres:

```
x = -domain + (i + 0.5) * (2*domain / w)
y = -domain + (j + 0.5) * (2*domain / h)
```

`+y is up`, `Γ > 0` is counter-clockwise. Field speed is clamped to `max_speed`
(default 6.0). Client-side plan: upload the field as an `RG32Float` texture and
sample it with hardware bilinear filtering when advecting particles.

## Client reader (reference, from probe.py)

1. read 4 bytes, big-endian → `N`
2. read exactly `N` bytes → payload
3. `w, h, frame_index = payload[0..8]` (uint16 LE, uint16 LE, uint32 LE)
4. remaining `w*h*2` float32 LE = the field
