# VortexClient — Swift + Metal frontend (macOS)

Advects ~1,000,000 particles through the velocity field streamed by the
`server` Elixir backend, with HDR feedback trails and a tonemapped
present pass. Zero third-party dependencies (AppKit, MetalKit, Network only).

## Run

Start the backend first (in `../server`: `./run.sh`), then here:

```sh
./run.sh            # swift build -c release && swift run -c release VortexClient
```

A 1000×1000 window opens; `[net] connected` prints once it reaches the server.
`Cmd-Q` quits. Point it elsewhere with `VORTEX_HOST` / `VORTEX_PORT`.

Requires the Xcode Command Line Tools (`xcode-select --install`) for `swift`.

## How it fits together each frame

1. **network** (`FieldClient`) — reads one frame per tick (4-byte BE length,
   then `w,h,frame_index,vortex_count,reserved`, the `float32` field, and a
   trailing `float32 (x,y,gamma)` list). The field goes into an `rg32Float`
   texture; the vortex list into a small buffer.
2. **advect** (compute) — every particle bilinearly samples the field and steps
   `pos += v·dt·speed`, respawning when it expires or leaves the domain. The
   field is **time-interpolated**: the two most recent 30 Hz frames are kept and
   blended by arrival time, so motion stays smooth between updates.
3. **trail** (one render pass into an `rgba16Float` texture) — a fullscreen fade
   quad multiplies the accumulator by `(1-fade)`, then particles are drawn
   additively as soft sprites, coloured by speed.
4. **present** — the HDR trail is Reinhard-tonemapped + gamma-corrected.
5. **markers** — the vortex cores are drawn as additive glows on top: warm =
   counter-clockwise (+Γ), cool = clockwise (−Γ), size by |Γ|. Toggle in the
   panel or with `v`.

## Controls

A floating **Controls** panel opens next to the window. "Look" sliders apply
instantly on the GPU; "Simulation" sliders and the buttons are sent to the
Elixir backend over the command channel.

- **Look:** speed, trail fade, point size, particle count
- **Simulation:** vortex count, grid resolution, circulation range
- **Actions:** reseed vortices, reset particles, clear trail, pause/resume

The same values are also on the keyboard (handy while the render window has
focus); current look values show in the title bar.

| key     | effect                                             |
|---------|----------------------------------------------------|
| `[` `]` | trail length (fade down / up)                      |
| `-` `=` | advection speed                                    |
| `,` `.` | point size                                         |
| `1`–`4` | particle count: 250k / 500k / 750k / 1M            |
| `v`     | show / hide vortex markers                         |
| `r`     | reset (clear) the trail                            |
| `Cmd-Q` | quit                                               |

Starting defaults lean toward silky filaments (`speed 0.45`, `fade 0.09`,
`size 1.1`, `N 500k`). Bake a look you like into the tunables at the top of
`Renderer.swift`; the colour ramp (indigo → cyan → gold) is `ramp()` in
`Shaders.swift`.

## Notes

- Shaders are compiled at runtime via `makeLibrary(source:)`, so there's no
  `.metal` file to bundle and no metallib path juggling under SwiftPM.
- Coordinates: world `[-1,1]²` maps to the field domain; `+y` is up; the domain
  is kept square inside the window via `params.aspect`.
- Black window? Confirm the backend is running and watch for `[net] connected`
  in the console; a `[net] failed`/`waiting` line means it can't reach the port.
