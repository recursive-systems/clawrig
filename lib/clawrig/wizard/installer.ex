defmodule Clawrig.Wizard.Installer do
  alias Clawrig.System.Commands

  def check_internet do
    Commands.impl().check_internet()
  end
end
