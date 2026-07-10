defmodule VortexField.Config do
  @moduledoc """
  Central tunables. Override any of these via application env, e.g.

      config :vortex_field, port: 4000

  but sane zero-config defaults are provided here.
  """

  def get(key), do: Application.get_env(:vortex_field, key, default(key))

  # networking
  defp default(:port), do: 4000

  # field grid streamed to the client (sampled on the domain below)
  defp default(:grid_w), do: 64
  defp default(:grid_h), do: 64
  # world-space domain the grid covers: [-x, x] x [-y, y]
  defp default(:domain), do: 1.0

  # simulation cadence
  defp default(:fps), do: 30
  defp default(:dt), do: 1.0 / 30.0

  # vortices
  defp default(:vortex_count), do: 18
  # circulation magnitude range (sign is randomised)
  defp default(:gamma_min), do: 0.5
  defp default(:gamma_max), do: 1.6
  # regularisation core radius (Krasny blob) for the *interaction* between vortices
  defp default(:delta_vortex), do: 0.05
  # regularisation used when sampling the field onto the grid (a touch larger => smoother)
  defp default(:delta_field), do: 0.07
  # recycle a vortex once it drifts past this radius from origin
  defp default(:recycle_radius), do: 1.5
  # spawn vortices within this radius of origin
  defp default(:spawn_radius), do: 0.85
  # lifetime range (seconds) after which a vortex is recycled with a fade
  defp default(:life_min), do: 6.0
  defp default(:life_max), do: 16.0
  # birth/death fade ramp (seconds) so recycling never pops the field
  defp default(:fade), do: 1.2

  # clamp on sampled field speed, keeps GPU advection well-behaved near cores
  defp default(:max_speed), do: 6.0

  defp default(_), do: nil
end
