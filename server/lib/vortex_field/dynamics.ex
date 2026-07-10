defmodule VortexField.Dynamics do
  @moduledoc """
  Point-vortex dynamics: the vortices themselves form a small Hamiltonian
  N-body system — each vortex is advected by the velocity the *others*
  induce at its location. Integrated with classical RK4.

  Each vortex is a map:

      %{x, y, gamma, age, life, fade}

  `gamma` is the base (signed) circulation; the *effective* circulation used
  everywhere folds in a smoothstep birth/death envelope so recycling a vortex
  never produces a visible pop in the field.
  """

  alias VortexField.Field

  @two_pi 2.0 * :math.pi()

  @type vortex :: %{
          x: float,
          y: float,
          gamma: float,
          age: float,
          life: float,
          fade: float
        }

  # ---- construction -------------------------------------------------------

  @spec init(non_neg_integer, map) :: [vortex]
  def init(count, cfg) do
    for _ <- 1..count, do: spawn_vortex(cfg)
  end

  @spec spawn_vortex(map) :: vortex
  def spawn_vortex(cfg) do
    r = cfg.spawn_radius * :math.sqrt(:rand.uniform())
    theta = @two_pi * :rand.uniform()
    sign = if :rand.uniform() < 0.5, do: -1.0, else: 1.0
    mag = cfg.gamma_min + (cfg.gamma_max - cfg.gamma_min) * :rand.uniform()
    life = cfg.life_min + (cfg.life_max - cfg.life_min) * :rand.uniform()

    %{
      x: r * :math.cos(theta),
      y: r * :math.sin(theta),
      gamma: sign * mag,
      age: 0.0,
      life: life,
      fade: cfg.fade
    }
  end

  # ---- envelope -----------------------------------------------------------

  @doc "Effective (faded) circulation of a vortex at its current age."
  @spec effective(vortex) :: float
  def effective(%{gamma: g, age: age, life: life, fade: fade}) do
    g * envelope(age, life, fade)
  end

  # fade <= 0 means "no fade": full strength while alive, nothing outside.
  defp envelope(age, life, fade) when fade <= 0.0 do
    if age >= 0.0 and age <= life, do: 1.0, else: 0.0
  end

  defp envelope(age, life, fade) do
    ramp_in = smoothstep(clamp01(age / fade))
    ramp_out = smoothstep(clamp01((life - age) / fade))
    ramp_in * ramp_out
  end

  defp smoothstep(t), do: t * t * (3.0 - 2.0 * t)
  defp clamp01(t) when t < 0.0, do: 0.0
  defp clamp01(t) when t > 1.0, do: 1.0
  defp clamp01(t), do: t

  @doc "Project vortices to the `{x, y, gamma_eff}` tuples the field sampler wants."
  @spec to_eff_tuples([vortex]) :: [{float, float, float}]
  def to_eff_tuples(vortices) do
    Enum.map(vortices, fn v -> {v.x, v.y, effective(v)} end)
  end

  # ---- integration --------------------------------------------------------

  @doc "Advance all vortices by `dt` with RK4, then age + recycle them."
  @spec step([vortex], float, map) :: [vortex]
  def step(vortices, dt, cfg) do
    gammas = Enum.map(vortices, &effective/1)
    p0 = Enum.map(vortices, fn v -> {v.x, v.y} end)
    delta = cfg.delta_vortex

    k1 = induced(p0, gammas, delta)
    k2 = induced(axpy(p0, k1, dt / 2.0), gammas, delta)
    k3 = induced(axpy(p0, k2, dt / 2.0), gammas, delta)
    k4 = induced(axpy(p0, k3, dt), gammas, delta)

    new_positions = rk4_combine(p0, k1, k2, k3, k4, dt)

    vortices
    |> Enum.zip(new_positions)
    |> Enum.map(fn {v, {x, y}} -> %{v | x: x, y: y, age: v.age + dt} end)
    |> Enum.map(&maybe_recycle(&1, cfg))
  end

  # velocity induced *on each vortex by all the others* (self excluded)
  defp induced(positions, gammas, delta) do
    d2 = delta * delta
    indexed = positions |> Enum.zip(gammas) |> Enum.with_index()

    for {{{xi, yi}, _gi}, i} <- indexed do
      Enum.reduce(indexed, {0.0, 0.0}, fn {{{xj, yj}, gj}, j}, {u, v} ->
        if i == j do
          {u, v}
        else
          dx = xi - xj
          dy = yi - yj
          r2 = dx * dx + dy * dy + d2
          k = gj / @two_pi / r2
          {u - k * dy, v + k * dx}
        end
      end)
    end
  end

  # p + a * k  (list of {x,y}, list of {u,v})
  defp axpy(p, k, a) do
    Enum.zip_with(p, k, fn {x, y}, {u, v} -> {x + a * u, y + a * v} end)
  end

  defp rk4_combine(p0, k1, k2, k3, k4, dt) do
    [p0, k1, k2, k3, k4]
    |> Enum.zip()
    |> Enum.map(fn {{x, y}, {u1, v1}, {u2, v2}, {u3, v3}, {u4, v4}} ->
      {
        x + dt / 6.0 * (u1 + 2.0 * u2 + 2.0 * u3 + u4),
        y + dt / 6.0 * (v1 + 2.0 * v2 + 2.0 * v3 + v4)
      }
    end)
  end

  defp maybe_recycle(v, cfg) do
    if v.age >= v.life or v.x * v.x + v.y * v.y > cfg.recycle_radius * cfg.recycle_radius do
      spawn_vortex(cfg)
    else
      v
    end
  end

  @doc false
  # kept for symmetry / potential debug use
  def field_velocity_at(vortices, x, y, delta),
    do: Field.velocity_at(to_eff_tuples(vortices), x, y, delta)
end
