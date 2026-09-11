defmodule Mesh.DailyAllowlistTest do
  use ExUnit.Case, async: true

  alias Mesh.CommandFabric

  test "daily verbs are allowlisted" do
    for cmd <- [:health_check, :help, :tailscale_status, :syncthing_status, :ensembly_status, :ensembly_channel_ir] do
      assert match?({:ok, _}, CommandFabric.authorize(cmd, actor: :agent)), inspect(cmd)
    end
  end

  test "shell still denied for agents" do
    assert {:error, {:not_allowlisted, :shell}} = CommandFabric.authorize(:shell, actor: :agent)
  end
end
