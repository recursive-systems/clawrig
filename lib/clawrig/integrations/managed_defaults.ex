defmodule Clawrig.Integrations.ManagedDefaults do
  @moduledoc """
  Reconciles managed defaults for browser-capable integrations.

  On appliance startup, ClawRig should enable its managed web search and
  Browser Use trial automatically when the user has not configured either one.
  Existing BYOK or managed config is left intact.
  """

  require Logger

  alias Clawrig.Integrations.BrowserUseBroker
  alias Clawrig.Integrations.Config
  alias Clawrig.Integrations.SearchProxy
  alias Clawrig.System.Commands

  @type changed_integration :: :search | :browser

  @spec reconcile() :: :noop | {:ok, [changed_integration()]}
  def reconcile do
    changes =
      []
      |> maybe_enable_search()
      |> maybe_enable_browser()
      |> Enum.reverse()

    case changes do
      [] ->
        :noop

      _ ->
        _ = Commands.impl().invalidate_agent_sessions()
        _ = Commands.impl().start_gateway()

        Logger.info(
          "[Integrations.ManagedDefaults] Enabled managed defaults: #{Enum.join(changes, ", ")}"
        )

        {:ok, changes}
    end
  end

  defp maybe_enable_search(changes) do
    cond do
      Config.search_mode() != :not_configured ->
        changes

      Config.search_auto_opt_out?() ->
        Logger.info(
          "[Integrations.ManagedDefaults] Leaving web search disabled because the user opted out"
        )

        changes

      true ->
        case SearchProxy.register_device() do
          {:ok, %{"token" => token}} when is_binary(token) and token != "" ->
            case Config.write_managed_search(token) do
              :ok ->
                [:search | changes]

              {:error, reason} ->
                Logger.warning(
                  "[Integrations.ManagedDefaults] Could not persist managed web search: #{reason}"
                )

                changes
            end

          {:ok, _body} ->
            Logger.warning(
              "[Integrations.ManagedDefaults] Search proxy register response missing token"
            )

            changes

          {:error, reason} ->
            Logger.warning(
              "[Integrations.ManagedDefaults] Managed web search auto-enable skipped: #{reason}"
            )

            changes
        end
    end
  end

  defp maybe_enable_browser(changes) do
    cond do
      Config.browser_mode() != :not_configured ->
        changes

      Config.browser_auto_opt_out?() ->
        Logger.info(
          "[Integrations.ManagedDefaults] Leaving Browser Use disabled because the user opted out"
        )

        changes

      true ->
        case BrowserUseBroker.register_device() do
          {:ok, body} ->
            case body["deviceToken"] || body["token"] do
              token when is_binary(token) and token != "" ->
                case Config.write_browser_trial(token) do
                  :ok ->
                    [:browser | changes]

                  {:error, reason} ->
                    Logger.warning(
                      "[Integrations.ManagedDefaults] Could not persist Browser Use trial: #{reason}"
                    )

                    changes
                end

              _ ->
                Logger.warning(
                  "[Integrations.ManagedDefaults] Browser Use broker register response missing device token"
                )

                changes
            end

          {:error, reason} ->
            Logger.warning(
              "[Integrations.ManagedDefaults] Browser Use auto-enable skipped: #{reason}"
            )

            changes
        end
    end
  end
end
