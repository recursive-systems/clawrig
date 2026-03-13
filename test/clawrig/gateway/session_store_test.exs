defmodule Clawrig.Gateway.SessionStoreTest do
  use ExUnit.Case, async: true

  alias Clawrig.Gateway.SessionStore

  test "invalidate_all clears stored sessions and deletes referenced session files" do
    home =
      Path.join(System.tmp_dir!(), "clawrig-session-store-#{System.unique_integer([:positive])}")

    sessions_dir = Path.join([home, ".openclaw", "agents", "main", "sessions"])
    session_file = Path.join(sessions_dir, "session-1.jsonl")

    File.mkdir_p!(sessions_dir)
    File.write!(session_file, "{\"type\":\"message\"}\n")

    File.write!(
      Path.join(sessions_dir, "sessions.json"),
      Jason.encode!(%{
        "agent:main:main" => %{
          "sessionId" => "abc",
          "sessionFile" => session_file
        }
      })
    )

    assert :ok = SessionStore.invalidate_all(home)
    assert File.read!(Path.join(sessions_dir, "sessions.json")) == "{}\n"
    refute File.exists?(session_file)

    File.rm_rf!(home)
  end

  test "invalidate_all bootstraps an empty main store when none exists" do
    home =
      Path.join(System.tmp_dir!(), "clawrig-session-store-#{System.unique_integer([:positive])}")

    sessions_dir = Path.join([home, ".openclaw", "agents", "main", "sessions"])

    assert :ok = SessionStore.invalidate_all(home)
    assert File.read!(Path.join(sessions_dir, "sessions.json")) == "{}\n"

    File.rm_rf!(home)
  end
end
