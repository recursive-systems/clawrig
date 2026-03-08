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
  @callback cpu_temperature() :: float() | nil
  @callback cpu_voltage() :: float() | nil
  @callback throttle_status() :: map()
  @callback tailscale_status() :: %{
              installed: boolean(),
              running: boolean(),
              ip: String.t() | nil,
              hostname: String.t() | nil
            }
  @callback tailscale_up(auth_key :: String.t()) :: :ok | {:error, String.t()}
  @callback tailscale_down() :: :ok | {:error, String.t()}
  @callback tailscale_install() :: :ok | {:error, String.t()}
  @callback autoheal_status() :: map()
  @callback autoheal_set_enabled(enabled :: boolean()) :: :ok | {:error, String.t()}
  @callback autoheal_run_now() :: :ok | {:error, String.t()}
  @callback autoheal_recent_log(limit :: non_neg_integer()) :: [map()]

  def impl do
    Application.get_env(:clawrig, :system_commands, Clawrig.System.MockCommands)
  end
end
