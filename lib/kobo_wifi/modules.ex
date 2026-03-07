defmodule KoboWifi.Modules do
  @moduledoc """
  Manages loading and unloading of MediaTek connectivity kernel modules.

  The Kobo Clara Colour uses a MediaTek MT8512 SoC with an integrated
  CONSYS_8512 WiFi+Bluetooth combo chip. The connectivity stack requires
  four kernel modules loaded in a specific order:

  1. `wmt_drv.ko` - WMT (Wireless Management Task) core driver
  2. `wmt_chrdev_wifi.ko` - WiFi character device adapter (loaded by wmt_loader)
  3. `wlan_drv_gen4m.ko` - MediaTek Gen4m WLAN driver (loaded by wmt_loader)
  4. `wmt_cdev_bt.ko` - Bluetooth character device driver (loaded by wmt_loader)

  Only `wmt_drv.ko` needs to be loaded manually via `insmod`. The remaining
  modules are auto-loaded by `wmt_loader` after the WMT core is ready.

  This module also handles mounting configfs and debugfs which are required
  by the MediaTek drivers.

  Low-level kernel module operations (`insmod`, `rmmod`, `/proc/modules`
  introspection) and system utilities (device node polling, pseudo-filesystem
  mounting) are delegated to the `KmodLoader` library.
  """

  require Logger

  @app :kobo_wifi

  @doc """
  Loads the WMT core kernel module and prepares the system for wmt_loader.

  This performs the following steps:
  1. Mount configfs at `/sys/kernel/config` (if not mounted)
  2. Mount debugfs at `/sys/kernel/debug` (if not mounted)
  3. Create firmware directory symlink (`/system/etc/firmware` -> `/lib/firmware`)
  4. Load `wmt_drv.ko` via insmod
  5. Wait for `/dev/wmtdetect` to appear
  6. Run `wmt_loader` which auto-loads remaining modules

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @spec load_all() :: :ok | {:error, term()}
  def load_all do
    Logger.info("[KoboWifi] Loading MediaTek connectivity modules...")

    with :ok <- KmodLoader.System.mount_pseudo_fs("configfs", "/sys/kernel/config"),
         :ok <- KmodLoader.System.mount_pseudo_fs("debugfs", "/sys/kernel/debug"),
         :ok <- ensure_firmware_symlink(),
         :ok <- load_wmt_drv(),
         :ok <- KmodLoader.System.wait_for_device("/dev/wmtdetect", device_wait_timeout()),
         :ok <- run_wmt_loader() do
      Logger.info("[KoboWifi] All connectivity modules loaded")
      :ok
    else
      {:error, reason} = error ->
        Logger.error("[KoboWifi] Module loading failed: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Unloads all connectivity kernel modules in reverse order.

  This is best-effort; individual module unload failures are logged but
  do not prevent unloading the remaining modules.
  """
  @spec unload_all() :: :ok
  def unload_all do
    Logger.info("[KoboWifi] Unloading connectivity modules...")

    # Unload in reverse dependency order
    KmodLoader.rmmod("wlan_drv_gen4m")
    KmodLoader.rmmod("wmt_chrdev_wifi")
    KmodLoader.rmmod("wmt_cdev_bt")
    KmodLoader.rmmod("wmt_drv")

    Logger.info("[KoboWifi] Connectivity modules unloaded")
    :ok
  end

  # -- Private: filesystem preparation --

  defp ensure_firmware_symlink do
    firmware_dir = Application.fetch_env!(@app, :firmware_dir)
    system_firmware_dir = Application.fetch_env!(@app, :system_firmware_dir)

    if File.exists?(system_firmware_dir) do
      Logger.debug("[KoboWifi] #{system_firmware_dir} already exists")
      :ok
    else
      parent = Path.dirname(system_firmware_dir)
      File.mkdir_p!(parent)

      case File.ln_s(firmware_dir, system_firmware_dir) do
        :ok ->
          Logger.info("[KoboWifi] Created symlink #{system_firmware_dir} -> #{firmware_dir}")
          :ok

        {:error, :eexist} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "[KoboWifi] Failed to create firmware symlink: #{inspect(reason)} (non-fatal)"
          )

          :ok
      end
    end
  end

  defp load_wmt_drv do
    module_path = Path.join(Application.fetch_env!(@app, :module_dir), "wmt_drv.ko")
    KmodLoader.insmod(module_path, skip_if_loaded: true)
  end

  defp run_wmt_loader do
    wmt_loader = "/usr/bin/wmt_loader"

    if File.exists?(wmt_loader) do
      Logger.info("[KoboWifi] Running wmt_loader (will auto-load remaining modules)...")

      case KmodLoader.System.safe_cmd(wmt_loader, []) do
        {:ok, output, exit_code} ->
          trimmed = String.trim(output)

          unless trimmed == "" do
            Logger.info("[KoboWifi] wmt_loader output (exit=#{exit_code}):\n#{trimmed}")
          end

          if wmt_loader_success?(exit_code, output) do
            Logger.info("[KoboWifi] wmt_loader completed successfully")

            # Wait for /dev/stpwmt to appear (created by wmt_loader)
            case KmodLoader.System.wait_for_device("/dev/stpwmt", device_wait_timeout()) do
              :ok ->
                :ok

              {:error, :timeout} ->
                Logger.warning("[KoboWifi] /dev/stpwmt did not appear (non-fatal)")
                :ok
            end
          else
            Logger.error("[KoboWifi] wmt_loader failed: exit=#{exit_code} #{trimmed}")

            {:error, {:wmt_loader_failed, exit_code}}
          end

        {:error, :enoent} ->
          Logger.error(
            "[KoboWifi] wmt_loader exec failed with :enoent - " <>
              "binary exists but cannot be executed. " <>
              "Likely cause: missing ELF dynamic linker on the rootfs. " <>
              "Check `readelf -l #{wmt_loader}` for the interpreter path."
          )

          {:error, {:exec_failed, wmt_loader, :enoent}}
      end
    else
      Logger.error("[KoboWifi] wmt_loader not found at #{wmt_loader}")
      {:error, {:not_found, wmt_loader}}
    end
  end

  # The stock Kobo wmt_loader binary is from an Android system. It successfully
  # loads all kernel modules but then exits 255 because it tries to set an
  # Android system property (persist.vendor.connsys.chipid) which doesn't exist
  # on our Linux-only Nerves system. We detect success by checking the output
  # for known success indicators rather than relying solely on exit code.
  defp wmt_loader_success?(0, _output), do: true

  defp wmt_loader_success?(_exit_code, output) do
    # wmt_loader prints these on successful module loading:
    #   "do kernel module init succeed: 0"
    #   "Success to insmod wmt wifi module"
    String.contains?(output, "do kernel module init succeed: 0") or
      String.contains?(output, "Success to insmod")
  end

  defp device_wait_timeout do
    Application.fetch_env!(@app, :device_wait_timeout)
  end
end
