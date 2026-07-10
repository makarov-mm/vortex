defmodule VortexField.Field do
  @moduledoc """
  Evaluation of the 2-D velocity field induced by a set of regularised
  point vortices (vortex-blob / Krasny regularisation).

  A vortex j at (xj, yj) with circulation Γj induces, at a point (x, y):

      dx = x - xj ; dy = y - yj ; r2 = dx*dx + dy*dy + δ²
      u = -Γj/(2π) * dy / r2
      v = +Γj/(2π) * dx / r2

  Γ > 0 is counter-clockwise. The field is the linear superposition over
  all vortices. `δ` removes the 1/r singularity at the core.

  A "vortex" here is the tuple `{x, y, gamma_eff}` where `gamma_eff` already
  folds in the birth/death fade envelope (see `VortexField.Dynamics`).
  """

  @two_pi 2.0 * :math.pi()

  @doc "Velocity {u, v} at world point (x, y) from a list of `{x, y, gamma}`."
  @spec velocity_at([{float, float, float}], float, float, float) :: {float, float}
  def velocity_at(vortices, x, y, delta) do
    d2 = delta * delta
    velocity_acc(vortices, x, y, d2, 0.0, 0.0)
  end

  defp velocity_acc([], _x, _y, _d2, u, v), do: {u, v}

  defp velocity_acc([{vx, vy, gamma} | rest], x, y, d2, u, v) do
    dx = x - vx
    dy = y - vy
    r2 = dx * dx + dy * dy + d2
    k = gamma / @two_pi / r2
    velocity_acc(rest, x, y, d2, u - k * dy, v + k * dx)
  end

  @doc """
  Rasterise the field onto a `w × h` grid over `[-domain, domain]²`.

  Returns iodata: `w*h` cells, row-major (j outer, i inner), each cell two
  little-endian float32s `<<u, v>>`. Speed is clamped to `max_speed`.

  Work is split across schedulers in row-blocks with `Task.async_stream`.
  """
  @spec rasterize([{float, float, float}], keyword) :: iodata
  def rasterize(vortices, opts) do
    w = Keyword.fetch!(opts, :w)
    h = Keyword.fetch!(opts, :h)
    domain = Keyword.fetch!(opts, :domain)
    delta = Keyword.fetch!(opts, :delta)
    max_speed = Keyword.fetch!(opts, :max_speed)

    # cell centres: x = -domain + (i + 0.5) * step_x
    step_x = 2.0 * domain / w
    step_y = 2.0 * domain / h
    d2 = delta * delta

    schedulers = System.schedulers_online()
    chunk = max(div(h + schedulers - 1, schedulers), 1)

    0..(h - 1)
    |> Enum.chunk_every(chunk)
    |> Task.async_stream(
      fn rows -> rows_to_binary(rows, vortices, w, domain, step_x, step_y, d2, max_speed) end,
      ordered: true,
      max_concurrency: schedulers,
      timeout: 5_000
    )
    |> Enum.map(fn {:ok, bin} -> bin end)
  end

  defp rows_to_binary(rows, vortices, w, domain, step_x, step_y, d2, max_speed) do
    for j <- rows, into: <<>> do
      y = -domain + (j + 0.5) * step_y
      row_to_binary(0, w, vortices, y, domain, step_x, d2, max_speed, <<>>)
    end
  end

  defp row_to_binary(i, w, _vortices, _y, _domain, _step_x, _d2, _max, acc) when i >= w,
    do: acc

  defp row_to_binary(i, w, vortices, y, domain, step_x, d2, max_speed, acc) do
    x = -domain + (i + 0.5) * step_x
    {u, v} = velocity_acc(vortices, x, y, d2, 0.0, 0.0)
    {u, v} = clamp_speed(u, v, max_speed)
    row_to_binary(i + 1, w, vortices, y, domain, step_x, d2, max_speed, <<
      acc::binary,
      u::float-little-32,
      v::float-little-32
    >>)
  end

  defp clamp_speed(u, v, max_speed) do
    s2 = u * u + v * v
    m2 = max_speed * max_speed

    if s2 > m2 do
      scale = max_speed / :math.sqrt(s2)
      {u * scale, v * scale}
    else
      {u, v}
    end
  end
end
