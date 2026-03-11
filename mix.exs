defmodule Clawrig.MixProject do
  use Mix.Project

  def project do
    [
      app: :clawrig,
      version: System.get_env("CLAWRIG_VERSION", "0.1.0-dev"),
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      releases: [
        clawrig: [
          include_erts: true,
          strip_beams: true,
          cookie: "clawrig-cookie",
          steps: [:assemble, &write_version_file/1]
        ]
      ],
      description: "Device management UI for OpenClaw on Raspberry Pi",
      source_url: "https://github.com/recursive-systems/clawrig",
      homepage_url: "https://clawrig.co",
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  def application do
    [
      mod: {Clawrig.Application, []},
      extra_applications: [:logger, :runtime_tools, :crypto]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp write_version_file(release) do
    File.write!(Path.join(release.path, "VERSION"), release.version)
    release
  end

  defp deps do
    [
      {:tidewave, "~> 0.5", only: [:dev]},
      {:igniter, "~> 0.6", only: [:dev, :test]},
      {:phoenix, "~> 1.8.4"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.1.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:mdex, "~> 0.11.6"},
      {:jason, "~> 1.2"},
      {:bandit, "~> 1.5"},
      {:req, "~> 0.5"},
      {:mint_web_socket, "~> 1.0"},
      {:systemd, "~> 0.6"}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "assets.setup", "assets.build"],
      "assets.setup": ["esbuild.install --if-missing"],
      "assets.build": ["compile", "esbuild clawrig", "esbuild clawrig_css"],
      "assets.deploy": [
        "esbuild clawrig --minify",
        "esbuild clawrig_css --minify",
        "phx.digest"
      ],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end
end
