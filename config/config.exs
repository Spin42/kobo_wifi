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
  interface_name: "wlan0"
