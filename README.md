# KoboWifi

Initializes WiFi hardware on Kobo e-readers by extracting proprietary firmware
and WMT binaries from stock Kobo system partitions, loading MediaTek
connectivity kernel modules, and starting the WMT stack so that `wlan0` is
available for [VintageNet](https://github.com/nerves-networking/vintage_net).

Currently supports the **Kobo Clara Colour** (MediaTek MT8512/MT8113 SoC with
integrated CONSYS_8512 WiFi+Bluetooth combo chip).

## Why this exists

The MediaTek WiFi hardware on Kobo e-readers requires proprietary firmware
blobs, WMT (Wireless Management Task) binaries, and out-of-tree kernel modules
that are not redistributable. These files live on the stock Kobo root partition
(`/dev/mmcblk0p10`) and must be extracted at runtime before WiFi can function
under a Nerves system.

KoboWifi bridges the gap between the stock Android-derived hardware stack and a
pure Linux/Nerves system by handling this extraction automatically on first boot,
then managing the full hardware initialization lifecycle through VintageNet's
power management interface.

## How it works

KoboWifi operates in two phases:

### Phase 1: First-boot firmware extraction

When the OTP application starts, `KoboWifi.Init` uses
[BlobCopy](https://github.com/nicola-spin42/blob_copy) to mount the stock Kobo
partition and extract:

- WiFi/BT firmware blobs (`/lib/firmware/`)
- WMT binaries (`wmt_loader`, `wmt_launcher`)
- WMT and Wireless configuration files (`/etc/*wmt*`, `/etc/Wireless/`)

A marker file (`/var/lib/kobo-wifi-firmware-copied`) is written after successful
extraction so this step is skipped on subsequent boots.

### Phase 2: On-demand hardware initialization

`KoboWifi.PowerManager` implements the `VintageNet.PowerManager` behaviour.
When VintageNet wants `wlan0` to exist, it calls `power_on/1`, which triggers:

1. Mount `configfs` and `debugfs` (required by MediaTek drivers)
2. Create firmware directory symlink (`/system/etc/firmware` -> `/lib/firmware`)
3. Load `wmt_drv.ko` kernel module via `insmod`
4. Run `wmt_loader` (auto-loads remaining modules: `wmt_chrdev_wifi.ko`,
   `wlan_drv_gen4m.ko`, `wmt_cdev_bt.ko`)
5. Start `wmt_launcher` daemon (supervised via `MuonTrap.Daemon`)
6. Enable WiFi by writing to `/dev/wmtWifi`

The kernel then creates `wlan0`. VintageNet detects it via netlink and proceeds
with wpa_supplicant, DHCP, etc.

## Installation

Add `kobo_wifi` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:kobo_wifi, path: "path/to/kobo_wifi"}
  ]
end
```

KoboWifi also depends on two sibling libraries that must be available:

- [`blob_copy`](https://github.com/nicola-spin42/blob_copy) -- idempotent file
  extraction from block device partitions
- [`kmod_loader`](https://github.com/nicola-spin42/kmod_loader) -- `insmod`/`rmmod`
  wrappers with idempotent operations

## Configuration

### Application config

Add to your Nerves project's `config.exs` or `target.exs`:

```elixir
# KoboWifi defaults match the stock Kobo Clara Colour layout.
# Override only what differs in your setup.
config :kobo_wifi,
  module_dir: "/drivers/mt8113t-ntx/mt66xx",
  firmware_dir: "/lib/firmware",
  system_firmware_dir: "/system/etc/firmware",
  device_wait_timeout: 10,
  wifi_enable_delay: 2_000,
  interface_name: "wlan0",
  blob_copy: [
    partition: "/dev/mmcblk0p10",
    mount_point: "/tmp/kobo-wifi-mount",
    marker_file: "/var/lib/kobo-wifi-firmware-copied",
    log_prefix: "KoboWifi",
    partition_wait_timeout: 30_000,
    mount_retries: 10,
    mount_retry_delay: 1_000,
    manifest: [
      %{source: "lib/firmware", dest: "/lib/firmware"},
      %{source: "usr/bin/wmt_loader", dest: "/usr/bin/wmt_loader", critical: true},
      %{source: "usr/bin/wmt_launcher", dest: "/usr/bin/wmt_launcher", critical: true},
      %{source: "etc/*wmt*", dest: "/etc"},
      %{source: "etc/*WMT*", dest: "/etc"},
      %{source: "etc/Wireless", dest: "/etc/Wireless"}
    ]
  ]
```

### VintageNet integration

Register the power manager and configure the WiFi interface:

```elixir
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
```

### Boot order

KoboWifi must start **before** VintageNet (`:nerves_pack`) so firmware
extraction completes before VintageNet attempts to power on WiFi. Configure
[Shoehorn](https://github.com/nerves-project/shoehorn) accordingly:

```elixir
config :shoehorn,
  init: [:nerves_runtime, :kobo_wifi, :nerves_pack, :nerves_kobo]
```

## Public API

```elixir
# Subscribe to firmware extraction events
KoboWifi.subscribe()
# => :ok
# Receive messages: {:kobo_wifi, :copying_firmware | :firmware_copied | :ready | {:error, reason}}

# Unsubscribe
KoboWifi.unsubscribe()
# => :ok

# Check current status
KoboWifi.status()
# => :ready | :initializing | :copying_firmware | {:error, reason}
```

## Architecture

```
                    ┌──────────────────────────────┐
                    │         VintageNet            │
                    │  (calls PowerManager when it  │
                    │   wants wlan0 to exist)       │
                    └──────────┬───────────────────┘
                               │ behaviour callbacks
                               ▼
┌─────────────┐     ┌──────────────────────────────┐
│  KoboWifi   │     │   KoboWifi.PowerManager      │
│  (public    │     │   power_on / power_off        │
│   API)      │     │                               │
│  subscribe  │     │ 1. wait_until_ready()         │
│  status     │     │ 2. Modules.load_all()         │
└─────────────┘     │ 3. Services.start_all()       │
       │            └───────┬──────────┬────────────┘
       │                    │          │
       ▼                    ▼          ▼
┌─────────────────┐  ┌───────────┐ ┌──────────────┐
│ KoboWifi.Init   │  │ KoboWifi  │ │ KoboWifi     │
│ (GenServer)     │  │ .Modules  │ │ .Services    │
│                 │  │           │ │              │
│ firmware        │  │ insmod    │ │ wmt_launcher │
│ extraction      │  │ wmt_loader│ │ /dev/wmtWifi │
│ via BlobCopy    │  │           │ │              │
└────────┬────────┘  └─────┬─────┘ └──────┬───────┘
         │                 │              │
         ▼                 ▼              ▼
    ┌──────────┐    ┌───────────┐  ┌─────────────┐
    │ BlobCopy │    │KmodLoader │  │  MuonTrap   │
    └──────────┘    └───────────┘  └─────────────┘
```

**Supervision tree:**

```
KoboWifi.Application
├── KoboWifi.DaemonSupervisor (DynamicSupervisor)
│   └── MuonTrap.Daemon (wmt_launcher, started on demand by Services)
└── KoboWifi.Init (GenServer)
```

## License

MIT -- see [LICENSE](LICENSE) for details.

Copyright 2026 Spin42
