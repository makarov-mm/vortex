defmodule VortexField.Simulation do
  @moduledoc """
  Owns the vortex state and drives the fixed-rate tick:

    1. integrate the vortices one `dt` (RK4) and recycle any that expired,
    2. rasterise the induced velocity field onto the grid,
    3. encode one frame and dispatch it to every connected client.

  Clients subscribe by registering under `{:frames}` in `VortexField.Registry`;
  dead subscribers are pruned automatically by the Registry.

  The runtime is steerable from clients via casts (see the command channel in
  `VortexField.Connection`): reseed the field, change the vortex count, resize
  the streamed grid, or adjust the circulation range.
  """

  use GenServer
  require Logger

  alias VortexField.{Config, Dynamics, Field, Protocol}

  @registry VortexField.Registry
  @topic :frames

  @max_vortices 200
  @min_grid 16
  @max_grid 200

  # ---- API ----------------------------------------------------------------

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Called by a connection process to start receiving `{:frame, iodata}`."
  def subscribe do
    {:ok, _} = Registry.register(@registry, @topic, nil)
    :ok
  end

  def reseed, do: GenServer.cast(__MODULE__, :reseed)
  def set_vortex_count(n), do: GenServer.cast(__MODULE__, {:set_vortex_count, n})
  def set_grid(w, h), do: GenServer.cast(__MODULE__, {:set_grid, w, h})
  def set_gamma(mn, mx), do: GenServer.cast(__MODULE__, {:set_gamma, mn, mx})

  @doc "Snapshot of current vortices (for debugging / tooling)."
  def vortices, do: GenServer.call(__MODULE__, :vortices)

  @doc "Compact state summary used by tests/tooling."
  def debug_state, do: GenServer.call(__MODULE__, :debug_state)

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

    {vcount, vdata} = Protocol.encode_vortices(eff)
    frame = Protocol.encode_frame(cfg.grid_w, cfg.grid_h, state.frame_index, vcount, field, vdata)
    dispatch(frame)

    schedule_tick(state.interval_ms)
    {:noreply, %{state | vortices: vortices, frame_index: state.frame_index + 1}}
  end

  # ---- command casts ------------------------------------------------------

  @impl true
  def handle_cast(:reseed, state) do
    n = length(state.vortices)
    Logger.info("reseed: #{n} vortices")
    {:noreply, %{state | vortices: Dynamics.init(n, state.cfg)}}
  end

  def handle_cast({:set_vortex_count, n}, state) do
    n = clamp(n, 1, @max_vortices)
    cur = state.vortices
    len = length(cur)

    vortices =
      cond do
        n == len -> cur
        n < len -> Enum.take(cur, n)
        true -> cur ++ for(_ <- 1..(n - len), do: Dynamics.spawn_vortex(state.cfg))
      end

    Logger.info("set vortex count: #{len} -> #{n}")
    {:noreply, %{state | cfg: %{state.cfg | vortex_count: n}, vortices: vortices}}
  end

  def handle_cast({:set_grid, w, h}, state) do
    w = clamp(w, @min_grid, @max_grid)
    h = clamp(h, @min_grid, @max_grid)
    Logger.info("set grid: #{state.cfg.grid_w}x#{state.cfg.grid_h} -> #{w}x#{h}")
    {:noreply, %{state | cfg: %{state.cfg | grid_w: w, grid_h: h}}}
  end

  def handle_cast({:set_gamma, mn, mx}, state) do
    mn = max(mn, 0.0)
    mx = max(mx, mn + 0.01)
    Logger.info("set gamma range: #{Float.round(mn, 2)}..#{Float.round(mx, 2)}")
    {:noreply, %{state | cfg: %{state.cfg | gamma_min: mn, gamma_max: mx}}}
  end

  # ---- calls --------------------------------------------------------------

  @impl true
  def handle_call(:vortices, _from, state), do: {:reply, state.vortices, state}

  def handle_call(:debug_state, _from, state) do
    reply = %{
      vortex_count: length(state.vortices),
      grid_w: state.cfg.grid_w,
      grid_h: state.cfg.grid_h,
      gamma_min: state.cfg.gamma_min,
      gamma_max: state.cfg.gamma_max,
      positions_hash: :erlang.phash2(Enum.map(state.vortices, &{&1.x, &1.y}))
    }

    {:reply, reply, state}
  end

  # ---- internals ----------------------------------------------------------

  defp dispatch(frame) do
    Registry.dispatch(@registry, @topic, fn subscribers ->
      for {pid, _} <- subscribers, do: send(pid, {:frame, frame})
    end)
  end

  defp schedule_tick(ms), do: Process.send_after(self(), :tick, ms)

  defp clamp(v, lo, _hi) when v < lo, do: lo
  defp clamp(v, _lo, hi) when v > hi, do: hi
  defp clamp(v, _lo, _hi), do: v

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
