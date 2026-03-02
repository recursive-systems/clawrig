defmodule Clawrig.Wizard.Launcher do
  alias Clawrig.System.Commands
  alias Clawrig.Wizard.{OAuth, State}

  def configure(mode, tg_token) do
    tokens = State.get(:oauth_tokens)

    case OAuth.ensure_fresh(tokens) do
      {:ok, fresh_tokens} ->
        State.put(:oauth_tokens, fresh_tokens)
        do_configure(mode, tg_token, fresh_tokens)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_configure(mode, tg_token, tokens) do
    home = System.get_env("HOME") || "/root"

    for dir <- [
          Path.join(home, ".openclaw"),
          Path.join([home, ".openclaw", "agents", "main", "agent"]),
          Path.join([home, ".openclaw", "oauth"])
        ] do
      File.mkdir_p!(dir)
    end

    config = %{
      "agents" => %{"defaults" => %{"model" => %{"primary" => "openai-codex/gpt-5.3-codex"}}},
      "gateway" => %{"mode" => "local"}
    }

    config =
      if tg_token do
        Map.put(config, "channels", %{
          "telegram" => %{"enabled" => true, "botToken" => tg_token, "dmPolicy" => "pairing"}
        })
      else
        config
      end

    File.write!(
      Path.join(home, ".openclaw/openclaw.json"),
      Jason.encode!(config, pretty: true)
    )

    OAuth.write_oauth_json(tokens)

    # Write launch intent
    intent = %{
      "mode" => to_string(mode),
      "at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    File.write!("launch-intent.json", Jason.encode!(intent, pretty: true))

    if tg_token do
      Commands.impl().run_openclaw(["plugins", "enable", "telegram"])
    end

    :ok
  rescue
    e -> {:error, "Configuration failed: #{Exception.message(e)}"}
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
        ["boot", "preflight", "restore_intent", "openai_auth", "telegram", "launch", "done"]
      else
        ["boot", "preflight", "new_install", "openai_auth", "telegram", "launch", "done"]
      end

    has_telegram = state.tg_token != nil

    receipt = %{
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "phase" => "phoenix-oobe-wizard-v1",
      "mode" => to_string(mode),
      "auth" => %{
        "provider" => "openai-codex",
        "method" => if(state.oauth_tokens, do: "oauth", else: "none"),
        "accountId" => get_in(state, [:oauth_tokens, :account_id])
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
      "preflightResult" => if(state.preflight_done, do: "PASS", else: "FAIL"),
      "verifyPassed" => state.verify_passed
    }

    File.write!("deployment-receipt.json", Jason.encode!(receipt, pretty: true))
    File.write!("wizard-state.json", Jason.encode!(wizard_state, pretty: true))

    {:ok, receipt}
  end
end
