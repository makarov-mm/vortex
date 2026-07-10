{:ok, _} = Registry.start_link(keys: :duplicate, name: VortexField.Registry)
{:ok, _} = VortexField.Simulation.start_link(nil)
alias VortexField.Simulation

pass = fn label, cond -> IO.puts([if(cond, do: "  PASS  ", else: "  FAIL  "), label]); cond end
settle = fn -> Process.sleep(60) end

Process.sleep(100)
s0 = Simulation.debug_state()
IO.puts("== command channel ==")
pass.("baseline defaults (18 vortices, 64x64)",
  s0.vortex_count == 18 and s0.grid_w == 64 and s0.grid_h == 64)

# reseed keeps the count and doesn't crash
Simulation.set_vortex_count(20)
settle.()
Simulation.reseed()
settle.()
pass.("reseed preserves vortex count", Simulation.debug_state().vortex_count == 20)

# set vortex count up and down
Simulation.set_vortex_count(40)
settle.()
pass.("set_vortex_count grows to 40", Simulation.debug_state().vortex_count == 40)
Simulation.set_vortex_count(6)
settle.()
pass.("set_vortex_count shrinks to 6", Simulation.debug_state().vortex_count == 6)
Simulation.set_vortex_count(100_000)
settle.()
pass.("vortex count clamps to 200", Simulation.debug_state().vortex_count == 200)

# grid resize + clamp
Simulation.set_grid(96, 120)
settle.()
g = Simulation.debug_state()
pass.("set_grid 96x120", g.grid_w == 96 and g.grid_h == 120)
Simulation.set_grid(4, 9999)
settle.()
g2 = Simulation.debug_state()
pass.("grid clamps to [16, 200]", g2.grid_w == 16 and g2.grid_h == 200)

# gamma range + ordering guard
Simulation.set_gamma(1.0, 2.5)
settle.()
gm = Simulation.debug_state()
pass.("set_gamma 1.0..2.5", abs(gm.gamma_min - 1.0) < 1.0e-6 and abs(gm.gamma_max - 2.5) < 1.0e-6)
Simulation.set_gamma(3.0, 1.0)
settle.()
gm2 = Simulation.debug_state()
pass.("gamma guard keeps max > min", gm2.gamma_max > gm2.gamma_min)

# still ticking after all that
f1 = Simulation.debug_state().positions_hash
Process.sleep(80)
f2 = Simulation.debug_state().positions_hash
pass.("simulation still advancing", f1 != f2)

IO.puts("")
