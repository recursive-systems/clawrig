defmodule Clawrig.Wizard.Installer do
  alias Clawrig.System.Commands

  def check_internet do
    Commands.impl().check_internet()
  end

  def check_openclaw do
    Commands.impl().check_openclaw()
  end

  def install_openclaw do
    Commands.impl().install_openclaw()
  end
end
