defmodule Mesh.HardAllowTest do
  use ExUnit.Case, async: false

  alias Mesh.HardAllow
  alias Mesh.CommandFabric

  setup do
    state_file = Path.join(System.tmp_dir!(), "mesh-hard-allow-#{System.unique_integer([:positive])}.json")
    audit = Path.join(System.tmp_dir!(), "mesh-audit-#{System.unique_integer([:positive])}.jsonl")
    System.put_env("MESH_HARD_ALLOW_STATE", state_file)
    System.put_env("MESH_AUDIT_LOG", audit)
    File.rm(state_file)
    File.rm(audit)
    on_exit(fn ->
      File.rm(state_file)
      File.rm(audit)
      System.delete_env("MESH_HARD_ALLOW_STATE")
      System.delete_env("MESH_AUDIT_LOG")
    end)

    %{state_file: state_file, audit: audit}
  end

  test "hard_allow status defaults ON with no bypass" do
    st = HardAllow.status()
    assert st.hard_allow == :on
    assert st.bypass_active == false
  end

  test "agent cannot start bypass or disable hard allow", %{audit: audit} do
    assert {:error, :agents_cannot_disable_hard_allow} =
             HardAllow.start_bypass(actor: :agent, ttl_ms: 60_000, reason: "nope")

    assert {:error, :agents_cannot_disable_hard_allow} = HardAllow.request_disable(:agent)
    assert {:error, :use_timed_bypass} = HardAllow.request_disable(:operator)

    body = File.read!(audit)
    assert body =~ "agents_cannot_disable_hard_allow" or body =~ "bypass_refuse"
    assert body =~ "disable_refuse"
  end

  test "unlisted verb denies + audits for agent", %{audit: audit} do
    assert {:error, {:not_allowlisted, :shell}} = CommandFabric.authorize(:shell, actor: :agent)
    body = File.read!(audit)
    assert body =~ "deny"
    assert body =~ "shell"
  end

  test "operator bypass TTL allows scoped off-list verb then snaps back", %{audit: audit} do
    assert {:ok, _} =
             HardAllow.start_bypass(
               actor: :operator,
               ttl_ms: 2_000,
               hosts: [HardAllow.hostname()],
               verbs: ["shell"],
               reason: "tinker"
             )

    assert {:ok, :shell} = CommandFabric.authorize(:shell, actor: :operator)
    body = File.read!(audit)
    assert body =~ "bypass_allow" or body =~ "bypass_start"

    # End early and confirm deny resumes
    assert :ok = HardAllow.end_bypass(actor: :operator)
    assert {:error, {:not_allowlisted, :shell}} = CommandFabric.authorize(:shell, actor: :operator)
  end

  test "allowlisted health_check still works" do
    assert {:ok, :health_check} = CommandFabric.authorize(:health_check, actor: :agent)
  end
end
