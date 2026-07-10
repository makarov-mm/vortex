# vortex

**Point vortices on the BEAM, a million particles on Metal.**

A real-time, fluid-like simulation split across two runtimes on purpose. A small
Hamiltonian vortex system runs in **Elixir**; it streams a velocity field over
TCP to a **Swift + Metal** client that advects ~1,000,000 particles through it
with feedback trails. Nothing is scripted — the motion is emergent.

Zero third-party dependencies on either side: Elixir stdlib (`:gen_tcp`,
`Registry`, `Task`) and Apple frameworks (Metal, MetalKit, AppKit, Network).

```
       ┌──────────────────────────── server (Elixir) ───────────────────────────┐
       │  ~18 point vortices advect *each other*  (2-D Biot–Savart, RK4)         │
       │  their superposition is rasterised onto a 64×64 grid  (parallel)        │
       └──────────────┬───────────────────────────────────────────▲─────────────┘
          field frames │  TCP {packet,4}, 30 Hz                    │  commands
          (LE floats:  │  w,h,frame,vortex_count + field + markers)│  reseed / count
           field+cores)▼                                           │  grid / gamma
       ┌───────────────────────────── client (Swift + Metal) ──────┴─────────────┐
       │  upload field → rg32Float texture (two frames, time-interpolated)        │
       │  compute: advect 1e6 particles, respawn on expiry/exit                   │
       │  HDR feedback trails → Reinhard tonemap → glowing vortex markers         │
       └─────────────────────────────────────────────────────────────────────────┘
```

The point of the split: the actual *dynamical system* lives on the BEAM, where
it's easy to reason about and spreads across every scheduler; the GPU only does
what GPUs are good at — moving a million things at once.

## Run

Prerequisites:
- **Elixir >= 1.14** (with Erlang/OTP) for the server — `brew install elixir`
- **Xcode Command Line Tools** for the client — `xcode-select --install`
- macOS 13+ on Apple Silicon

Start the server, then the client (two terminals):

```sh
cd server && ./run.sh          # listening on tcp/4000, 18 vortices, 64x64 @ 30 fps
```

```sh
cd client && ./run.sh          # builds + opens the window, connects to 127.0.0.1:4000
```

Point the client elsewhere with `VORTEX_HOST` / `VORTEX_PORT`.

## Controls

A floating **Controls** panel opens beside the window.

- **Look (instant, GPU):** speed, trail fade, point size, particle count
- **Simulation (sent to the backend):** vortex count, grid resolution, circulation
- **Actions:** show/hide vortices, reseed, reset particles, clear trail, pause

The same look values are on the keyboard while the render window has focus
(`[ ]` trail, `- =` speed, `, .` size, `1-4` count, `v` markers, `r` clear,
`Cmd-Q` quit); current values show in the title bar.

## Wire protocol (summary)

TCP in Erlang `{packet, 4}` mode, so every message is prefixed by a 4-byte
big-endian length. Everything else is little-endian.

**Server -> client**, one frame per tick:

```
uint16 w, uint16 h, uint32 frame_index, uint16 vortex_count, uint16 reserved
float32 field[w*h*2]        # row-major, interleaved (u, v)
float32 vortices[vc*3]      # (x, y, gamma_eff) markers
```

**Client -> server**, commands (opcode first byte):

```
0x01                    reseed vortices
0x02  uint16 n          set vortex count      (1..200)
0x03  uint16 w, h       set grid              (16..200)
0x04  float32 mn, mx    set circulation range
```

Full details and a reference reader are in [`server/README.md`](server/README.md).

## Layout

```
vortex/
├── server/                      Elixir backend (mix project, app :vortex_field)
│   ├── lib/vortex_field/
│   │   ├── field.ex             regularised point-vortex field + rasteriser
│   │   ├── dynamics.ex          RK4 vortex N-body, birth/death fade, recycling
│   │   ├── protocol.ex          frame + marker encoding
│   │   ├── simulation.ex        tick loop, command channel, frame dispatch
│   │   ├── tcp_server.ex        acceptor
│   │   ├── connection.ex        per-client process (frames out, commands in)
│   │   ├── config.ex            tunables
│   │   └── application.ex       supervision tree
│   ├── verify.exs / verify2.exs analytic, wire-format, and command checks
│   ├── probe.py / cmd_test.py   live probes (ASCII quiver, command tests)
│   └── run.sh
└── client/                      Swift + Metal frontend (SwiftPM, flat layout)
    ├── main.swift               NSApplication + window + MTKView
    ├── Renderer.swift           pipelines, field interpolation, particle + marker passes
    ├── Shaders.swift            Metal source (compiled at runtime)
    ├── FieldClient.swift        TCP reader + command sender (Network.framework)
    ├── ControlPanel.swift       AppKit control panel
    ├── Package.swift
    └── run.sh
```

## Verification

The server side is checked without a GPU:

```sh
cd server
./run.sh verify      # 14 checks: single-vortex analytics, superposition, dipole
                     #            self-propulsion, envelope, frame + marker bytes
./run.sh verify2     # 10 checks: reseed / count / grid / gamma command casts
./run.sh cmdtest     # live: commands drive the stream (grid change is observable)
./run.sh probe       # live: ASCII quiver + vortex summary
```

## License

MIT (c) 2026 Mykhailo Makarov
