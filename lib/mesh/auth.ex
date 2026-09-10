defmodule Mesh.Auth do
  @moduledoc """
  Bearer token for mutating HTTP. Fail closed if no token is configured.
  """

  def token do
    case System.get_env("MESH_API_TOKEN") do
      t when is_binary(t) and byte_size(t) > 0 ->
        String.trim(t)

      _ ->
        case File.read(Path.expand("~/.config/mesh/token")) do
          {:ok, t} ->
            case String.trim(t) do
              "" -> nil
              trimmed -> trimmed
            end

          _ ->
            nil
        end
    end
  end

  @doc """
  {:ok, token} | {:error, :token_not_configured} | {:error, :unauthorized}
  """
  def check(conn) do
    case token() do
      nil ->
        {:error, :token_not_configured}

      expected ->
        case presented(conn) do
          nil ->
            {:error, :unauthorized}

          got ->
            if secure_same?(expected, got), do: :ok, else: {:error, :unauthorized}
        end
    end
  end

  defp presented(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> t] -> t
      ["bearer " <> t] -> t
      _ -> nil
    end
  end

  defp secure_same?(a, b) when byte_size(a) == byte_size(b) do
    Plug.Crypto.secure_compare(a, b)
  end

  defp secure_same?(_, _), do: false
end
