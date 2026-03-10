defmodule KoboWifi.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/nicola-spin42/kobo_wifi"

  def project do
    [
      app: :kobo_wifi,
      version: @version,
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      description: description(),
      package: package()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {KoboWifi.Application, []},
      env: [
        module_dir: "/drivers/mt8113t-ntx/mt66xx",
        firmware_dir: "/lib/firmware",
        system_firmware_dir: "/system/etc/firmware",
        device_wait_timeout: 10,
        wifi_enable_delay: 2_000,
        interface_name: "wlan0"
      ]
    ]
  end

  defp deps do
    [
      {:kmod_loader, github: "Spin42/kmod_loader"},
      {:muontrap, "~> 1.7"},
      {:vintage_net, "~> 0.13", optional: true},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end

  defp docs do
    [
      main: "KoboWifi",
      source_url: @source_url,
      extras: ["README.md"]
    ]
  end

  defp description do
    "Initializes WiFi hardware on Kobo e-readers by loading MediaTek " <>
      "connectivity kernel modules and starting the WMT stack so that " <>
      "wlan0 is available for VintageNet."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end
end
