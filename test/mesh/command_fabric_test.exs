defmodule Mesh.CommandFabricTest do
  use ExUnit.Case, async: false

  alias Mesh.CommandFabric

  test "shell is not allowlisted" do
    assert {:error, {:not_allowlisted, :shell}} = CommandFabric.broadcast(:shell, [])
  end

  test "health_check runs locally" do
    assert [{node, {:ok, result}}] = CommandFabric.broadcast(:health_check, [])
    assert node == Node.self()
    assert result.node == Node.self()
  end

  test "restart_service denied when service allowlist is empty" do
    assert [{_, {:error, :service_not_allowlisted}}] =
             CommandFabric.broadcast(:restart_service, service: "sshd")
  end

  test "pull_git and deploy are off the allowlist" do
    assert {:error, {:not_allowlisted, :pull_git}} = CommandFabric.broadcast(:pull_git, [])
    assert {:error, {:not_allowlisted, :deploy}} = CommandFabric.broadcast(:deploy, [])
  end

  test "sunshine and mutate syncthing stay off the allowlist" do
    assert {:error, {:not_allowlisted, :trigger_syncthing_scan}} =
             CommandFabric.broadcast(:trigger_syncthing_scan, [])

    assert {:error, {:not_allowlisted, :sunshine_status}} =
             CommandFabric.broadcast(:sunshine_status, [])
  end
end
