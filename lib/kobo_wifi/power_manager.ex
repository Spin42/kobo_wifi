defmodule KoboWifi.PowerManager do
  @moduledoc """
  VintageNet PowerManager implementation for Kobo WiFi hardware.

  This module implements the `VintageNet.PowerManager` behaviour to integrate
  the Kobo Clara Colour's MediaTek CONSYS_8512 WiFi hardware with VintageNet.

  VintageNet calls `power_on/1` when it wants the `wlan0` interface to exist.
  This triggers the full hardware initialization sequence:

  1. Mount configfs and debugfs (required by MediaTek drivers)
  2. Create firmware directory symlink
  3. Load `wmt_drv.ko` kernel module
  4. Run `wmt_loader` (auto-loads remaining modules)
  5. Start `wmt_launcher` daemon
  6. Enable WiFi via `/dev/wmtWifi`

  After step 6, the kernel creates the `wlan0` interface. VintageNet detects
  this via netlink and proceeds to configure it (bring it up, start
  wpa_supplicant, etc.).

  ## Configuration

  Add to your `config.exs`:

      config :vintage_net,
        power_managers: [
          {KoboWifi.PowerManager, [ifname: "wlan0", watchdog_timeout: 120_000]}
        ]

  The `watchdog_timeout` should be generous since the MediaTek hardware
  initialization can take several seconds.
  """

  @behaviour VintageNet.PowerManager

  require Logger

  # Hold time after power_on before VintageNet considers a reset.
  # 10 minutes is generous for the MediaTek init sequence.
  @power_on_hold_time 600_000

  # Time to allow for graceful power-off (WMT shutdown)
  @time_to_power_off 5_000

  # Minimum time to keep power off before turning on again
  @min_power_off_time 2_000

  @impl VintageNet.PowerManager
  def init(args) do
    ifname = Keyword.fetch!(args, :ifname)
    Logger.info("[KoboWifi.PowerManager] Initialized for #{ifname}")
    {:ok, %{ifname: ifname}}
  end

  @impl VintageNet.PowerManager
  def power_on(state) do
    Logger.info("[KoboWifi.PowerManager] Powering on WiFi for #{state.ifname}...")

    # Wait for firmware extraction to complete before attempting hardware init.
    # KoboWifi.Init runs asynchronously and may still be copying firmware
    # from the stock Kobo partition when VintageNet first calls power_on.
    case KoboWifi.Init.wait_until_ready() do
      :ok ->
        Logger.info("[KoboWifi.PowerManager] Firmware ready, starting hardware init...")

      {:error, reason} ->
        Logger.error(
          "[KoboWifi.PowerManager] Firmware not available: #{inspect(reason)}, " <>
            "attempting hardware init anyway"
        )
    end

    # Run the full hardware init sequence.
    # This can return before wlan0 appears - VintageNet will wait for it.
    case do_power_on() do
      :ok ->
        Logger.info("[KoboWifi.PowerManager] WiFi hardware power-on sequence complete")
        {:ok, state, @power_on_hold_time}

      {:error, reason} ->
        # Log error but still return :ok - VintageNet's watchdog will
        # eventually trigger a power cycle if the interface never appears.
        Logger.error(
          "[KoboWifi.PowerManager] WiFi power-on failed: #{inspect(reason)}, " <>
            "watchdog will retry"
        )

        {:ok, state, @power_on_hold_time}
    end
  end

  @impl VintageNet.PowerManager
  def start_powering_off(state) do
    Logger.info("[KoboWifi.PowerManager] Starting graceful WiFi shutdown for #{state.ifname}...")

    # Stop WMT services (wmt_launcher, disable WiFi)
    KoboWifi.Services.stop_all()

    {:ok, state, @time_to_power_off}
  end

  @impl VintageNet.PowerManager
  def power_off(state) do
    Logger.info("[KoboWifi.PowerManager] Completing WiFi power off for #{state.ifname}...")

    # Unload kernel modules
    KoboWifi.Modules.unload_all()

    {:ok, state, @min_power_off_time}
  end

  @impl VintageNet.PowerManager
  def handle_info(msg, state) do
    Logger.debug("[KoboWifi.PowerManager] Unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp do_power_on do
    with :ok <- KoboWifi.Modules.load_all(),
         :ok <- KoboWifi.Services.start_all() do
      :ok
    end
  rescue
    e ->
      Logger.error("[KoboWifi.PowerManager] Hardware init raised: #{Exception.message(e)}")
      {:error, {:raised, Exception.message(e)}}
  end
end
