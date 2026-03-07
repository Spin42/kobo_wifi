import Config

# Default configuration for KoboWifi
#
# All values here match the stock Kobo Clara Colour layout.
# Override in your Nerves project's config as needed.

config :kobo_wifi,
  # Directory where out-of-tree MediaTek kernel modules are installed
  module_dir: "/drivers/mt8113t-ntx/mt66xx",
  # Directory for WiFi firmware blobs
  firmware_dir: "/lib/firmware",
  # MediaTek drivers expect firmware at this Android-style path;
  # a symlink to firmware_dir is created here during init
  system_firmware_dir: "/system/etc/firmware",
  # Seconds to wait for device nodes to appear after loading modules
  device_wait_timeout: 10,
  # Delay (ms) after enabling WiFi via /dev/wmtWifi for wlan0 to appear
  wifi_enable_delay: 2_000,
  # WiFi network interface name
  interface_name: "wlan0",

  # BlobCopy configuration — first-boot extraction of proprietary firmware
  # from the stock Kobo partition
  blob_copy: [
    partition: "/dev/mmcblk0p10",
    mount_point: "/tmp/kobo-wifi-mount",
    marker_file: "/var/lib/kobo-wifi-firmware-copied",
    log_prefix: "KoboWifi",
    partition_wait_timeout: 30_000,
    mount_retries: 10,
    mount_retry_delay: 1_000,
    manifest: [
      # WiFi/BT firmware blobs — entire firmware directory tree
      %{source: "lib/firmware", dest: "/lib/firmware"},
      # WMT loader — hardware init and module auto-loading
      %{source: "usr/bin/wmt_loader", dest: "/usr/bin/wmt_loader", critical: true},
      # WMT launcher — firmware loading daemon
      %{source: "usr/bin/wmt_launcher", dest: "/usr/bin/wmt_launcher", critical: true},
      # WMT configuration files
      %{source: "etc/*wmt*", dest: "/etc"},
      %{source: "etc/*WMT*", dest: "/etc"},
      # Wireless subsystem configuration
      %{source: "etc/Wireless", dest: "/etc/Wireless"}
    ]
  ]
