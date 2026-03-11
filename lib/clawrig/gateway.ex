defmodule Clawrig.Gateway do
  @moduledoc false

  def operator_module do
    Application.get_env(:clawrig, :gateway_operator_client, Clawrig.Gateway.OperatorClient)
  end

  def session_key do
    Application.get_env(:clawrig, :gateway_chat_session_key, "agent:main:main")
  end

  def operator_topic do
    "clawrig:gateway:operator"
  end

  def chat_topic(session_key \\ session_key()) do
    "clawrig:chat:" <> session_key
  end
end
