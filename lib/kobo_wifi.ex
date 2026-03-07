defmodule KoboWifi do
  @moduledoc """
  Initializes WiFi hardware on Kobo e-readers for use with VintageNet.

  On Kobo e-readers (specifically the Clara Colour with MT8512/MT8113 SoC),
  WiFi requires proprietary firmware blobs, WMT (Wireless Management Task)
  binaries, and MediaTek connectivity kernel modules from the stock Kobo
  system partition. This library handles two concerns:

  ## 1. First-Boot Firmware Extraction (OTP Application)

  On first boot, the `KoboWifi.Init` GenServer extracts proprietary files
  from the stock Kobo root partition (`/dev/mmcblk0p10`):

  - WiFi/BT firmware blobs (`/lib/firmware/*`)
  - WMT binaries (`wmt_loader`, `wmt_launcher`)
  - WMT and Wireless configuration files

  This must happen before VintageNet tries to power on the WiFi hardware.
  Ensure `:kobo_wifi` is in the shoehorn boot order before `:nerves_pack`:

      config :shoehorn, init: [:nerves_runtime, :kobo_wifi, :nerves_pack, :nerves_kobo]

  ## 2. VintageNet PowerManager Integration

  `KoboWifi.PowerManager` implements the `VintageNet.PowerManager` behaviour.
  When VintageNet wants `wlan0` to exist, it calls `power_on/1` which:

  - Mounts configfs/debugfs
  - Creates firmware symlink
  - Loads `wmt_drv.ko` kernel module
  - Runs `wmt_loader` (auto-loads remaining modules)
  - Starts `wmt_launcher` daemon
  - Enables WiFi via `/dev/wmtWifi`

  The kernel then creates `wlan0`. VintageNet detects it via netlink and
  proceeds to bring it up, start wpa_supplicant, obtain DHCP, etc.

  ## Configuration

      # config.exs / target.exs
      config :kobo_wifi,
        kobo_partition: "/dev/mmcblk0p10",
        module_dir: "/drivers/mt8113t-ntx/mt66xx",
        marker_file: "/var/lib/kobo-wifi-firmware-copied"

      config :vintage_net,
        power_managers: [
          {KoboWifi.PowerManager, [ifname: "wlan0", watchdog_timeout: 120_000]}
        ],
        config: [
          {"usb0", %{type: VintageNetDirect}},
          {"wlan0", %{
            type: VintageNetWiFi,
            vintage_net_wifi: %{
              networks: [%{ssid: "MyNetwork", psk: "secret", key_mgmt: :wpa_psk}]
            },
            ipv4: %{method: :dhcp}
          }}
        ]

  ## Events

  Subscribers receive `{:kobo_wifi, event}` messages for firmware extraction:

  - `:copying_firmware` - extracting firmware from stock partition
  - `:firmware_copied` - extraction complete
  - `:ready` - firmware is available (either freshly copied or already present)
  - `{:error, reason}` - firmware extraction failed
  """

  @doc """
  Subscribes the calling process to firmware extraction events.

  The subscriber receives `{:kobo_wifi, event}` messages as the firmware
  extraction progresses. If extraction has already completed (or failed),
  the current state is sent immediately.

  See module docs for the full list of events.
  """
  @spec subscribe() :: :ok
  def subscribe do
    KoboWifi.Init.subscribe()
  end

  @doc """
  Unsubscribes the calling process from firmware extraction events.
  """
  @spec unsubscribe() :: :ok
  def unsubscribe do
    KoboWifi.Init.unsubscribe()
  end

  @doc """
  Returns the current firmware extraction status.

  Returns one of:
  - `:ready` - firmware is available
  - `:initializing` - extraction hasn't started yet
  - `:copying_firmware` - extracting firmware from stock partition
  - `{:error, reason}` - extraction failed
  """
  @spec status() :: KoboWifi.Init.status()
  def status do
    KoboWifi.Init.status()
  end
end
