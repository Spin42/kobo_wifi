defmodule KoboWifi.Services do
  @moduledoc """
  Manages the WMT (Wireless Management Task) services.

  After kernel modules are loaded by `KoboWifi.Modules`, this module handles
  starting the WMT launcher daemon and enabling WiFi:

  1. Start `wmt_launcher` daemon for firmware loading
  2. Enable WiFi by writing `1` to `/dev/wmtWifi`

  The `wlan0` interface is then created by the kernel. VintageNet detects it
  via netlink and handles bringing it up, starting wpa_supplicant, and DHCP.

  Daemons are started as `MuonTrap.Daemon` processes under
  `KoboWifi.DaemonSupervisor` (a `DynamicSupervisor`), giving proper
  OTP supervision, automatic cleanup on crash, and no need for manual
  PID tracking or `killall`.

  This module is called by `KoboWifi.PowerManager` -- it should not be used
  directly unless you are managing WiFi outside of VintageNet.
  """

  require Logger

  @app :kobo_wifi
  @daemon_supervisor KoboWifi.DaemonSupervisor

  @doc """
  Runs the WMT service startup sequence.

  This must be called after `KoboWifi.Modules.load_all/0` has completed.

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @spec start_all() :: :ok | {:error, term()}
  def start_all do
    Logger.info("[KoboWifi] Starting WMT services...")

    with :ok <- start_wmt_launcher(),
         :ok <- enable_wifi() do
      Logger.info("[KoboWifi] WMT services started, WiFi enabled")
      :ok
    else
      {:error, reason} = error ->
        Logger.error("[KoboWifi] WMT service startup failed: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Stops WMT services.
  """
  @spec stop_all() :: :ok
  def stop_all do
    Logger.info("[KoboWifi] Stopping WMT services...")

    # Disable WiFi
    disable_wifi()

    # Terminate wmt_launcher daemon
    terminate_daemon(:wmt_launcher)

    Logger.info("[KoboWifi] WMT services stopped")
    :ok
  end

  # -- Individual service steps --

  @doc """
  Starts the `wmt_launcher` daemon.

  `wmt_launcher` handles firmware loading for the MediaTek combo chip.
  It runs under `KoboWifi.DaemonSupervisor` via `MuonTrap.Daemon` with
  the firmware path as an argument.
  """
  @spec start_wmt_launcher() :: :ok | {:error, term()}
  def start_wmt_launcher do
    binary = "/usr/bin/wmt_launcher"

    if File.exists?(binary) do
      firmware_dir = Application.fetch_env!(@app, :firmware_dir)

      start_daemon(:wmt_launcher, binary, ["-p", firmware_dir],
        log_output: :debug,
        log_prefix: "[KoboWifi] wmt_launcher: ",
        stderr_to_stdout: true
      )
    else
      Logger.error("[KoboWifi] wmt_launcher not found at #{binary}")
      {:error, {:not_found, binary}}
    end
  end

  @doc """
  Enables WiFi by writing `1` to `/dev/wmtWifi`.

  This activates the WiFi subsystem on the MediaTek combo chip and causes
  the kernel to create the wlan0 interface.
  """
  @spec enable_wifi() :: :ok | {:error, term()}
  def enable_wifi do
    wmt_wifi = "/dev/wmtWifi"
    ifname = Application.fetch_env!(@app, :interface_name)
    max_attempts = 5
    retry_delay = 2_000

    if File.exists?(wmt_wifi) do
      do_enable_wifi(wmt_wifi, ifname, max_attempts, retry_delay)
    else
      Logger.error("[KoboWifi] #{wmt_wifi} not found - WMT stack may not be ready")
      {:error, {:device_not_found, wmt_wifi}}
    end
  end

  defp do_enable_wifi(wmt_wifi, ifname, attempts_left, retry_delay) when attempts_left > 0 do
    attempt = 6 - attempts_left
    Logger.info("[KoboWifi] Enabling WiFi via #{wmt_wifi} (attempt #{attempt}/5)...")

    case File.write(wmt_wifi, "1") do
      :ok ->
        Logger.info("[KoboWifi] Wrote '1' to #{wmt_wifi}, waiting for #{ifname}...")

        if wait_for_interface(ifname, retry_delay) do
          Logger.info("[KoboWifi] #{ifname} interface is up")
          :ok
        else
          Logger.warning(
            "[KoboWifi] #{ifname} did not appear after writing to #{wmt_wifi}" <>
              if(attempts_left > 1, do: ", retrying...", else: ", giving up")
          )

          if attempts_left > 1 do
            # Disable before retrying - reset the WiFi state
            File.write(wmt_wifi, "0")
            Process.sleep(500)
            do_enable_wifi(wmt_wifi, ifname, attempts_left - 1, retry_delay)
          else
            {:error, :interface_not_created}
          end
        end

      {:error, reason} ->
        Logger.error("[KoboWifi] Failed to write to #{wmt_wifi}: #{inspect(reason)}")

        if attempts_left > 1 do
          Logger.info("[KoboWifi] Retrying in #{retry_delay}ms...")
          Process.sleep(retry_delay)
          do_enable_wifi(wmt_wifi, ifname, attempts_left - 1, retry_delay)
        else
          {:error, {:wifi_enable_failed, reason}}
        end
    end
  end

  defp do_enable_wifi(_wmt_wifi, _ifname, _attempts_left, _retry_delay) do
    {:error, :max_attempts_reached}
  end

  # Polls for the network interface to appear in sysfs.
  # Returns true if found within timeout_ms, false otherwise.
  defp wait_for_interface(ifname, timeout_ms) do
    sysfs_path = "/sys/class/net/#{ifname}"
    poll_interval = 200
    iterations = div(timeout_ms, poll_interval)

    Enum.any?(1..max(iterations, 1), fn i ->
      if File.exists?(sysfs_path) do
        true
      else
        if i < iterations, do: Process.sleep(poll_interval)
        false
      end
    end)
  end

  @doc """
  Disables WiFi by writing `0` to `/dev/wmtWifi`.
  """
  @spec disable_wifi() :: :ok
  def disable_wifi do
    wmt_wifi = "/dev/wmtWifi"

    if File.exists?(wmt_wifi) do
      case File.write(wmt_wifi, "0") do
        :ok ->
          Logger.info("[KoboWifi] WiFi disabled via #{wmt_wifi}")

        {:error, reason} ->
          Logger.warning("[KoboWifi] Failed to disable WiFi: #{inspect(reason)}")
      end
    end

    :ok
  end

  defp start_daemon(id, binary, args, opts) do
    child_spec =
      Supervisor.child_spec(
        {MuonTrap.Daemon, [binary, args, opts]},
        id: id
      )

    case DynamicSupervisor.start_child(@daemon_supervisor, child_spec) do
      {:ok, _pid} ->
        Logger.info("[KoboWifi] Started #{id}")
        :ok

      {:error, {:already_started, _pid}} ->
        Logger.info("[KoboWifi] #{id} already running")
        :ok

      {:error, reason} = error ->
        Logger.error("[KoboWifi] Failed to start #{id}: #{inspect(reason)}")
        error
    end
  end

  defp terminate_daemon(id) do
    case find_daemon_pid(id) do
      {:ok, pid} ->
        DynamicSupervisor.terminate_child(@daemon_supervisor, pid)
        Logger.info("[KoboWifi] Stopped #{id}")

      :not_found ->
        Logger.debug("[KoboWifi] #{id} was not running")
    end
  end

  defp find_daemon_pid(id) do
    @daemon_supervisor
    |> DynamicSupervisor.which_children()
    |> Enum.find_value(:not_found, fn
      {^id, pid, _, _} when is_pid(pid) -> {:ok, pid}
      _ -> false
    end)
  end
end
