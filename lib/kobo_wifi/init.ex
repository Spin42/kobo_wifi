defmodule KoboWifi.Init do
  @moduledoc """
  GenServer that manages the WiFi firmware extraction lifecycle.

  On startup, extracts proprietary firmware and WMT binaries from the stock
  Kobo partition (first boot only). This must complete before VintageNet
  starts, so `kobo_wifi` should be in the shoehorn boot order before
  `nerves_pack`.

  The hardware initialization (kernel modules, WMT stack) is handled
  separately by `KoboWifi.PowerManager` when VintageNet requests it.

  Subscribers receive messages as firmware extraction progresses:

      KoboWifi.subscribe()
      # receive do
      #   {:kobo_wifi, :firmware_copied} -> ...
      #   {:kobo_wifi, :ready} -> ...
      #   {:kobo_wifi, {:error, reason}} -> ...
      # end
  """

  use GenServer

  require Logger

  @type status :: :initializing | :copying_firmware | :ready | {:error, term()}

  # -- Client API --

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the current firmware extraction status.
  """
  @spec status() :: status()
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc """
  Blocks until firmware extraction is complete or the timeout expires.

  Returns `:ok` if firmware is ready, or `{:error, reason}` if extraction
  failed or timed out. This is used by `KoboWifi.PowerManager` to ensure
  firmware is available before attempting hardware initialization.
  """
  @spec wait_until_ready(timeout()) :: :ok | {:error, term()}
  def wait_until_ready(timeout \\ 60_000) do
    case status() do
      :ready ->
        :ok

      {:error, _reason} = error ->
        error

      _in_progress ->
        # Subscribe, then check status again to avoid a race where
        # extraction completes between the status check and subscribe.
        subscribe()

        try do
          case status() do
            :ready -> :ok
            {:error, _reason} = error -> error
            _ -> await_ready(timeout)
          end
        after
          unsubscribe()
        end
    end
  end

  defp await_ready(timeout) do
    receive do
      {:kobo_wifi, :ready} ->
        :ok

      {:kobo_wifi, {:error, _reason} = error} ->
        error

      {:kobo_wifi, _other} ->
        # Intermediate event (e.g. :copying_firmware, :firmware_copied), keep waiting
        await_ready(timeout)
    after
      timeout ->
        {:error, :firmware_wait_timeout}
    end
  end

  @doc """
  Subscribes the calling process to firmware extraction events.

  The subscriber will receive messages of the form `{:kobo_wifi, event}` where
  event is one of:

  - `:copying_firmware` - firmware extraction from stock partition has started
  - `:firmware_copied` - firmware extraction completed successfully
  - `:ready` - firmware is available (either freshly copied or already present)
  - `{:error, reason}` - firmware extraction failed

  If extraction has already completed (or failed) by the time `subscribe/0`
  is called, the subscriber immediately receives the current state.
  """
  @spec subscribe() :: :ok
  def subscribe do
    GenServer.call(__MODULE__, {:subscribe, self()})
  end

  @doc """
  Unsubscribes the calling process from firmware extraction events.
  """
  @spec unsubscribe() :: :ok
  def unsubscribe do
    GenServer.call(__MODULE__, {:unsubscribe, self()})
  end

  # -- Server callbacks --

  @impl true
  def init(_opts) do
    state = %{status: :initializing, subscribers: MapSet.new()}
    send(self(), :initialize)
    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, state.status, state}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    Process.monitor(pid)
    new_subscribers = MapSet.put(state.subscribers, pid)

    # If we're already past initializing, send the current state immediately
    case state.status do
      :initializing -> :ok
      terminal -> send(pid, {:kobo_wifi, terminal})
    end

    {:reply, :ok, %{state | subscribers: new_subscribers}}
  end

  def handle_call({:unsubscribe, pid}, _from, state) do
    {:reply, :ok, %{state | subscribers: MapSet.delete(state.subscribers, pid)}}
  end

  @impl true
  def handle_info(:initialize, state) do
    new_status = do_initialize(state.subscribers)
    {:noreply, %{state | status: new_status}}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: MapSet.delete(state.subscribers, pid)}}
  end

  # -- Private --

  defp do_initialize(subscribers) do
    Logger.info("[KoboWifi] Starting WiFi firmware extraction...")

    broadcast(subscribers, :copying_firmware)

    case BlobCopy.ensure_copied(blob_copy_config()) do
      :ok ->
        broadcast(subscribers, :firmware_copied)
        broadcast(subscribers, :ready)
        Logger.info("[KoboWifi] WiFi firmware is available")
        :ready

      {:error, reason} = error ->
        broadcast(subscribers, error)
        Logger.error("[KoboWifi] Firmware extraction failed: #{inspect(reason)}")
        error
    end
  end

  defp blob_copy_config do
    Application.fetch_env!(:kobo_wifi, :blob_copy)
    |> BlobCopy.Config.new!()
  end

  defp broadcast(subscribers, event) do
    Enum.each(subscribers, fn pid ->
      send(pid, {:kobo_wifi, event})
    end)
  end
end
