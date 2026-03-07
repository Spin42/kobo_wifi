defmodule KoboWifi.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {DynamicSupervisor, strategy: :one_for_one, name: KoboWifi.DaemonSupervisor},
      KoboWifi.Init
    ]

    opts = [strategy: :one_for_one, name: KoboWifi.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
