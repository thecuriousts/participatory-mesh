defmodule Mesh.MixProject do
  use Mix.Project

  def project do
    [
      app: :mesh,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      releases: releases()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :runtime_tools, :inets, :ssl, :public_key],
      mod: {Mesh.Application, []}
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:req, "~> 0.5"},
      {:plug_cowboy, "~> 2.6"}
    ]
  end

  defp aliases do
    [
      test: ["test"]
    ]
  end

  defp releases do
    [
      mesh: [
        include_executables_for: [:unix],
        applications: [mesh: :permanent],
        vm_args: "config/vm.args.eex"
      ]
    ]
  end
end
