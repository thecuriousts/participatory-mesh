defmodule Mesh.Audit do
  @moduledoc """
  Append-only JSONL of mutating commands. Not a chat log.
  """

  def record(event) when is_map(event) do
    path = audit_path()
    File.mkdir_p!(Path.dirname(path))
    line = Jason.encode!(Map.put(event, "ts", DateTime.utc_now())) <> "\n"
    File.write(path, line, [:append])
  end

  defp audit_path do
    System.get_env("MESH_AUDIT_LOG") ||
      Path.expand("~/.local/share/mesh/audit.jsonl")
  end
end
