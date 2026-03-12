defmodule Clawrig.Wizard.Launcher do
  alias Clawrig.System.Commands

  @doc """
  Apply runtime-only configuration and write launch intent.
  The base openclaw.json (model + gateway config) is pre-baked in the golden image.
  Auth is handled by `openclaw onboard` during the OpenAI wizard step.
  """
  def finalize(mode, tg_token, tg_chat_id \\ nil) do
    # Ensure appliance exec defaults (security: full, ask: off)
    Clawrig.Integrations.Config.write_exec_defaults()

    home = System.get_env("HOME") || "/root"
    config_path = Path.join(home, ".openclaw/openclaw.json")

    if tg_token do
      # Merge Telegram channel config into existing openclaw.json.
      # Telegram.save_config/3 may have already run `openclaw channels add`,
      # so only write if channels aren't already present.
      config =
        case File.read(config_path) do
          {:ok, contents} -> Jason.decode!(contents)
          _ -> %{}
        end

      tg_channel = get_in(config, ["channels", "telegram"])

      if tg_channel do
        # Channels already configured (by save_config or openclaw channels add).
        # Ensure allowFrom is set — save_config should have done this, but
        # handle the edge case where it was skipped or failed.
        if tg_chat_id && !Map.has_key?(tg_channel, "allowFrom") do
          config = put_in(config, ["channels", "telegram", "allowFrom"], [tg_chat_id])
          File.write!(config_path, Jason.encode!(config, pretty: true))
        end
      else
        # Channels not configured yet — write the full config.
        tg_config = %{"enabled" => true, "botToken" => tg_token, "dmPolicy" => "allowlist"}

        tg_config =
          if tg_chat_id,
            do: Map.put(tg_config, "allowFrom", [tg_chat_id]),
            else: tg_config

        config = put_in(config, [Access.key("channels", %{}), "telegram"], tg_config)
        File.write!(config_path, Jason.encode!(config, pretty: true))
      end

      Commands.impl().run_openclaw(["plugins", "enable", "telegram"])
    end

    # Write launch intent (audit trail)
    intent = %{
      "mode" => to_string(mode),
      "at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    File.mkdir_p!(Path.join(home, ".openclaw"))

    File.write!(
      Path.join(home, ".openclaw/launch-intent.json"),
      Jason.encode!(intent, pretty: true)
    )

    :ok
  rescue
    e -> {:error, "Finalization failed: #{Exception.message(e)}"}
  end

  def start_gateway do
    case Commands.impl().gateway_status() do
      :running ->
        :ok

      :stopped ->
        Commands.impl().start_gateway()
        Process.sleep(5000)

        case Commands.impl().gateway_status() do
          :running -> :ok
          :stopped -> {:error, "Gateway may still be starting up."}
        end
    end
  end

  def check_pairing do
    case Commands.impl().run_openclaw(["pairing", "list", "telegram", "--json"]) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, %{"requests" => requests}} when requests != [] ->
            {:ok, requests}

          _ ->
            {:ok, []}
        end

      _ ->
        {:ok, []}
    end
  end

  def approve_pairing(code) do
    case Commands.impl().run_openclaw(["pairing", "approve", "telegram", code, "--notify"]) do
      {_, 0} -> :ok
      {err, _} -> {:error, String.trim(err)}
    end
  end

  def health_check do
    Process.sleep(1000)
    {_, doctor_code} = Commands.impl().run_openclaw(["doctor"])
    {_, status_code} = Commands.impl().run_openclaw(["status"])

    if doctor_code == 0 || status_code == 0 do
      :ok
    else
      {:error, "Some checks reported warnings."}
    end
  end

  def write_receipt(state) do
    mode = state.mode || :new

    core_path =
      if mode == :restore do
        ["boot", "preflight", "restore_intent", "openai_auth", "telegram", "done"]
      else
        ["boot", "preflight", "new_install", "openai_auth", "telegram", "done"]
      end

    has_telegram = state.tg_token != nil

    receipt = %{
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "phase" => "phoenix-oobe-wizard-v1",
      "mode" => to_string(mode),
      "auth" => %{
        "provider" => state.provider_type || "openai-codex",
        "method" =>
          cond do
            state.provider_done and state.provider_auth_method -> state.provider_auth_method
            state.provider_done -> "api-key"
            true -> "none"
          end,
        "providerName" => state[:provider_name],
        "baseUrl" => state[:provider_base_url],
        "modelId" => state[:provider_model_id]
      },
      "core_path" => core_path,
      "restore" =>
        if(mode == :restore,
          do: %{"sourceType" => "backup-file", "validationStatus" => "placeholder-pending"},
          else: nil
        ),
      "optional" => [
        %{
          "name" => "telegram_setup",
          "status" => if(has_telegram, do: "configured", else: "skipped")
        }
      ],
      "status" => "pass"
    }

    wizard_state = %{
      "mode" => to_string(mode),
      "optional" => %{"telegram" => has_telegram},
      "completedAt" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "preflightResult" => if(state.preflight_done, do: "PASS", else: "FAIL")
    }

    home = System.get_env("HOME") || "/root"
    oc_dir = Path.join(home, ".openclaw")
    File.mkdir_p!(oc_dir)

    File.write!(
      Path.join(oc_dir, "deployment-receipt.json"),
      Jason.encode!(receipt, pretty: true)
    )

    File.write!(Path.join(oc_dir, "wizard-state.json"), Jason.encode!(wizard_state, pretty: true))

    {:ok, receipt}
  end
end
