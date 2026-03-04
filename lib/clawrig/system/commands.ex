defmodule Clawrig.System.Commands do
  @callback scan_networks() :: [map()]
  @callback connect_wifi(ssid :: String.t(), password :: String.t()) ::
              {:ok, String.t() | nil} | {:error, term()}
  @callback start_hotspot() :: :ok | {:error, term()}
  @callback stop_hotspot() :: :ok | {:error, term()}
  @callback check_internet() :: boolean()
  @callback run_openclaw(args :: [String.t()]) :: {String.t(), integer()}
  @callback gateway_status() :: :running | :stopped
  @callback start_gateway() :: :ok | {:error, String.t()}
  @callback install_gateway() :: :ok | {:error, String.t()}
  @callback detect_local_ip() :: String.t() | nil
  @callback has_ethernet_ip() :: boolean()
  @callback run_codex_exec(prompt :: String.t(), schema_path :: String.t()) ::
              {String.t(), integer()}

  def impl do
    Application.get_env(:clawrig, :system_commands, Clawrig.System.MockCommands)
  end
end
