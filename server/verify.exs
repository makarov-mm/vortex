alias VortexField.{Field, Dynamics, Protocol}

two_pi = 2.0 * :math.pi()
pass = fn label, cond -> IO.puts([if(cond, do: "  PASS  ", else: "  FAIL  "), label]); cond end
approx = fn a, b, tol -> abs(a - b) <= tol end

IO.puts("== 1. single vortex: analytic superposition ==")

delta = 0.07
d2 = delta * delta
g = 1.0
vs = [{0.0, 0.0, g}]

# analytic: u = -g/2pi * dy/r2 ; v = +g/2pi * dx/r2   (dx=x-vx, dy=y-vy)
analytic = fn x, y ->
  dx = x - 0.0
  dy = y - 0.0
  r2 = dx * dx + dy * dy + d2
  {-g / two_pi * dy / r2, g / two_pi * dx / r2}
end

ok1 =
  for {x, y} <- [{0.5, 0.0}, {0.0, 0.5}, {-0.3, 0.2}, {0.13, -0.41}], reduce: true do
    acc ->
      {u, v} = Field.velocity_at(vs, x, y, delta)
      {au, av} = analytic.(x, y)
      acc and approx.(u, au, 1.0e-12) and approx.(v, av, 1.0e-12)
  end

pass.("velocity_at matches closed form at 4 probe points", ok1)

# orientation: at 3 o'clock a CCW (+) vortex must push +y (upward)
{_u3, v3} = Field.velocity_at(vs, 0.5, 0.0, delta)
pass.("Γ>0 is counter-clockwise (v>0 at 3 o'clock)", v3 > 0.0)

# at 12 o'clock it must push -x (leftward)
{u12, _} = Field.velocity_at(vs, 0.0, 0.5, delta)
pass.("Γ>0 pushes -x at 12 o'clock", u12 < 0.0)

IO.puts("\n== 2. superposition: two vortices add linearly ==")
a = [{-0.4, 0.0, 1.0}]
b = [{0.4, 0.0, -0.7}]
both = a ++ b
{ua, va} = Field.velocity_at(a, 0.1, 0.2, delta)
{ub, vb} = Field.velocity_at(b, 0.1, 0.2, delta)
{uab, vab} = Field.velocity_at(both, 0.1, 0.2, delta)
pass.("field is linear in the vortices", approx.(uab, ua + ub, 1.0e-12) and approx.(vab, va + vb, 1.0e-12))

IO.puts("\n== 3. dipole self-propulsion (RK4 step) ==")
# +Γ above, -Γ below the x-axis => the pair must translate along +x with ~no net y drift
cfg = %{delta_vortex: 0.05, recycle_radius: 99.0, spawn_radius: 0.1,
        gamma_min: 1.0, gamma_max: 1.0, life_min: 1.0e6, life_max: 1.0e6, fade: 0.0}

dipole = [
  %{x: 0.0, y: 0.1, gamma: 1.0, age: 100.0, life: 1.0e6, fade: 0.0},
  %{x: 0.0, y: -0.1, gamma: -1.0, age: 100.0, life: 1.0e6, fade: 0.0}
]

stepped = Dynamics.step(dipole, 0.05, cfg)
[p1, p2] = stepped
pass.("both vortices advanced in +x", p1.x > 0.0 and p2.x > 0.0)
pass.("vertical separation preserved (symmetric drift)",
  approx.(p1.y, 0.1, 1.0e-3) and approx.(p2.y, -0.1, 1.0e-3))

IO.puts("\n== 4. birth/death envelope ==")
young = %{gamma: 2.0, age: 0.0, life: 10.0, fade: 1.0}
mid   = %{gamma: 2.0, age: 5.0, life: 10.0, fade: 1.0}
dying = %{gamma: 2.0, age: 10.0, life: 10.0, fade: 1.0}
pass.("effective Γ = 0 at birth", Dynamics.effective(young) == 0.0)
pass.("effective Γ = base at mid-life", approx.(Dynamics.effective(mid), 2.0, 1.0e-9))
pass.("effective Γ = 0 at death", approx.(Dynamics.effective(dying), 0.0, 1.0e-9))

IO.puts("\n== 5. wire format roundtrip (as the Swift client will parse it) ==")
w = 4
h = 3
field_vs = [{0.05, -0.02, 1.0}, {-0.1, 0.1, -0.6}]

iodata =
  Field.rasterize(field_vs, w: w, h: h, domain: 1.0, delta: delta, max_speed: 6.0)

frame = Protocol.encode_frame(w, h, 42, iodata) |> IO.iodata_to_binary()

<<pw::unsigned-little-16, ph::unsigned-little-16, idx::unsigned-little-32, rest::binary>> = frame
pass.("header decodes (w,h,frame_index)", pw == w and ph == h and idx == 42)
pass.("payload byte length == 8 + w*h*2*4", byte_size(frame) == 8 + w * h * 2 * 4)

# re-sample cell (i=1, j=2) directly and compare with the bytes at that offset
i = 1
j = 2
step_x = 2.0 / w
step_y = 2.0 / h
cx = -1.0 + (i + 0.5) * step_x
cy = -1.0 + (j + 0.5) * step_y
{eu, ev} = Field.velocity_at(field_vs, cx, cy, delta)

cell = j * w + i
off = cell * 8
<<_::binary-size(off), gu::float-little-32, gv::float-little-32, _::binary>> = rest
pass.("grid cell (1,2) bytes match a direct field sample (float32 tol)",
  approx.(gu, eu, 1.0e-5) and approx.(gv, ev, 1.0e-5))

IO.puts("")
