defmodule VortexField.Simulation do
  @moduledoc """
  Owns the vortex state and drives the fixed-rate tick:

    1. integrate the vortices one `dt` (RK4) and recycle any that expired,
    2. rasterise the induced velocity field onto the grid,
    3. encode one frame and dispatch it to every connected client.

  Clients subscribe by registering under `{:frames}` in `VortexField.Registry`;
  dead subscribers are pruned automatically by the Registry.
  """

  use GenServer
  require Logger

  alias VortexField.{Config, Dynamics, Field, Protocol}

  @registry VortexField.Registry
  @topic :frames

  # ---- API ----------------------------------------------------------------

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Called by a connection process to start receiving `{:frame, iodata}`."
  def subscribe do
    {:ok, _} = Registry.register(@registry, @topic, nil)
    :ok
  end

  @doc "Snapshot of current vortices (for debugging / tooling)."
  def vortices, do: GenServer.call(__MODULE__, :vortices)

  # ---- server -------------------------------------------------------------

  @impl true
  def init(_) do
    cfg = load_config()
    :rand.seed(:exsss)
    vortices = Dynamics.init(cfg.vortex_count, cfg)
    interval_ms = round(1000 / cfg.fps)

    state = %{
      cfg: cfg,
      vortices: vortices,
      frame_index: 0,
      interval_ms: interval_ms
    }

    Logger.info(
      "vortex simulation started: #{cfg.vortex_count} vortices, " <>
        "#{cfg.grid_w}x#{cfg.grid_h} grid @ #{cfg.fps} fps"
    )

    schedule_tick(interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    %{cfg: cfg} = state

    vortices = Dynamics.step(state.vortices, cfg.dt, cfg)
    eff = Dynamics.to_eff_tuples(vortices)

    field =
      Field.rasterize(eff,
        w: cfg.grid_w,
        h: cfg.grid_h,
        domain: cfg.domain,
        delta: cfg.delta_field,
        max_speed: cfg.max_speed
      )

    frame = Protocol.encode_frame(cfg.grid_w, cfg.grid_h, state.frame_index, field)
    dispatch(frame)

    schedule_tick(state.interval_ms)
    {:noreply, %{state | vortices: vortices, frame_index: state.frame_index + 1}}
  end

  @impl true
  def handle_call(:vortices, _from, state), do: {:reply, state.vortices, state}

  # ---- internals ----------------------------------------------------------

  defp dispatch(frame) do
    Registry.dispatch(@registry, @topic, fn subscribers ->
      for {pid, _} <- subscribers, do: send(pid, {:frame, frame})
    end)
  end

  defp schedule_tick(ms), do: Process.send_after(self(), :tick, ms)

  defp load_config do
    %{
      port: Config.get(:port),
      grid_w: Config.get(:grid_w),
      grid_h: Config.get(:grid_h),
      domain: Config.get(:domain),
      fps: Config.get(:fps),
      dt: Config.get(:dt),
      vortex_count: Config.get(:vortex_count),
      gamma_min: Config.get(:gamma_min),
      gamma_max: Config.get(:gamma_max),
      delta_vortex: Config.get(:delta_vortex),
      delta_field: Config.get(:delta_field),
      recycle_radius: Config.get(:recycle_radius),
      spawn_radius: Config.get(:spawn_radius),
      life_min: Config.get(:life_min),
      life_max: Config.get(:life_max),
      fade: Config.get(:fade),
      max_speed: Config.get(:max_speed)
    }
  end
end
