defmodule Mesh.HardGateTest do
  use ExUnit.Case, async: false

  alias Mesh.HardGate
  alias Mesh.CommandFabric

  setup do
    gate = Path.join(System.tmp_dir!(), "mesh-gate-#{System.unique_integer([:positive])}.json")
    audit = Path.join(System.tmp_dir!(), "mesh-audit-#{System.unique_integer([:positive])}.jsonl")
    System.put_env("MESH_GATE_STATE", gate)
    System.put_env("MESH_AUDIT_LOG", audit)
    File.rm(gate)
    File.rm(audit)
    on_exit(fn ->
      File.rm(gate)
      File.rm(audit)
      System.delete_env("MESH_GATE_STATE")
      System.delete_env("MESH_AUDIT_LOG")
    end)

    %{gate: gate, audit: audit}
  end

  test "gate status defaults ON with no bypass" do
    st = HardGate.status()
    assert st.gate == :on
    assert st.bypass_active == false
  end

  test "agent cannot start bypass or disable gate", %{audit: audit} do
    assert {:error, :agents_cannot_disable_gate} =
             HardGate.start_bypass(actor: :agent, ttl_ms: 60_000, reason: "nope")

    assert {:error, :agents_cannot_disable_gate} = HardGate.request_disable(:agent)
    assert {:error, :use_timed_bypass} = HardGate.request_disable(:operator)

    body = File.read!(audit)
    assert body =~ "agents_cannot_disable_gate" or body =~ "bypass_refuse"
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
             HardGate.start_bypass(
               actor: :operator,
               ttl_ms: 2_000,
               hosts: [HardGate.hostname()],
               verbs: ["shell"],
               reason: "tinker"
             )

    assert {:ok, :shell} = CommandFabric.authorize(:shell, actor: :operator)
    body = File.read!(audit)
    assert body =~ "bypass_allow" or body =~ "bypass_start"

    # End early and confirm deny resumes
    assert :ok = HardGate.end_bypass(actor: :operator)
    assert {:error, {:not_allowlisted, :shell}} = CommandFabric.authorize(:shell, actor: :operator)
  end

  test "allowlisted health_check still works" do
    assert {:ok, :health_check} = CommandFabric.authorize(:health_check, actor: :agent)
  end
end
