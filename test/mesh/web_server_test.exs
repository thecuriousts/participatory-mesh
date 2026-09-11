defmodule Mesh.WebServerTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  @opts []

  setup do
    token = "test-token-32-bytes-long-padpad"
    audit = Path.join(System.tmp_dir!(), "mesh-audit-#{System.unique_integer([:positive])}.jsonl")
    System.put_env("MESH_API_TOKEN", token)
    System.put_env("MESH_AUDIT_LOG", audit)

    on_exit(fn ->
      System.delete_env("MESH_API_TOKEN")
      System.delete_env("MESH_AUDIT_LOG")
      File.rm(audit)
    end)

    {:ok, token: token, audit: audit}
  end

  test "GET /health is open" do
    conn = conn(:get, "/health") |> Mesh.WebServer.Router.call(@opts)
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert Map.has_key?(body, "self")
    assert Map.has_key?(body, "quorum")
  end

  test "POST /command without bearer is 401", %{token: _token} do
    conn =
      conn(:post, "/command", Jason.encode!(%{command: "health_check"}))
      |> put_req_header("content-type", "application/json")
      |> Mesh.WebServer.Router.call(@opts)

    assert conn.status == 401
    assert Jason.decode!(conn.resp_body)["error"] == "unauthorized"
  end

  test "POST /command with token runs health_check", %{token: token} do
    conn =
      conn(:post, "/command", Jason.encode!(%{command: "health_check"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")
      |> Mesh.WebServer.Router.call(@opts)

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert is_list(body["result"])
  end

  test "POST /command shell is 403 even with token", %{token: token} do
    conn =
      conn(:post, "/command", Jason.encode!(%{command: "shell"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")
      |> Mesh.WebServer.Router.call(@opts)

    assert conn.status == 403
    assert Jason.decode!(conn.resp_body)["error"] == "not_allowlisted"
  end

  test "POST /command wrong token is 401" do
    conn =
      conn(:post, "/command", Jason.encode!(%{command: "health_check"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer wrong-token-32-bytes-long-pad")
      |> Mesh.WebServer.Router.call(@opts)

    assert conn.status == 401
  end
end
