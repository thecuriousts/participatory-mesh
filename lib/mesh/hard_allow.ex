defmodule Mesh.HardAllow do
  @moduledoc """
  Deny-by-default mesh hard allow with operator-only timed bypass.

  Law (ops MESH-HARD-ALLOW.md):
  - Default ON — CommandFabric allowlist is the mutate surface
  - Audit always (allow | deny | bypass)
  - Agents cannot disable hard allow
  - Operator may open a TTL + scoped bypass; it snaps back ON
  """

  @type actor :: :operator | :agent | atom()
  @type command :: atom() | String.t()

  @doc "Current hard-allow view for CLI/status."
  def status do
    st = load_state()
    bypass = active_bypass(st)

    %{
      hard_allow: :on,
      bypass_active: bypass != nil,
      bypass: bypass,
      note: "hard allow stays ON; bypass only softens allowlist for the operator within TTL/scope"
    }
  end

  @doc """
  Start operator bypass. Agents are refused.
  opts: :ttl_ms (required), :hosts (list), :verbs (list of strings/atoms), :reason, :actor
  """
  def start_bypass(opts) when is_list(opts) do
    actor = Keyword.get(opts, :actor, :agent)

    if actor != :operator do
      _ = audit(%{"event" => "bypass_refuse", "actor" => to_string(actor), "reason" => "agents_cannot_disable_hard_allow"})
      {:error, :agents_cannot_disable_hard_allow}
    else
      ttl = Keyword.fetch!(opts, :ttl_ms)
      now = DateTime.utc_now()
      expires = DateTime.add(now, ttl, :millisecond)

      bypass = %{
        "started_at" => DateTime.to_iso8601(now),
        "expires_at" => DateTime.to_iso8601(expires),
        "hosts" => Enum.map(Keyword.get(opts, :hosts, []), &to_string/1),
        "verbs" => Enum.map(Keyword.get(opts, :verbs, []), &to_string/1),
        "reason" => to_string(Keyword.get(opts, :reason, "tinker")),
        "bypass" => "operator"
      }

      st = load_state() |> Map.put("bypass", bypass)
      save_state(st)

      _ =
        audit(%{
          "event" => "bypass_start",
          "actor" => "operator",
          "bypass" => "operator",
          "expires_at" => bypass["expires_at"],
          "hosts" => bypass["hosts"],
          "verbs" => bypass["verbs"],
          "reason" => bypass["reason"]
        })

      {:ok, bypass}
    end
  end

  @doc "End bypass early. Operator only."
  def end_bypass(opts \\ []) do
    actor = Keyword.get(opts, :actor, :agent)

    if actor != :operator do
      _ = audit(%{"event" => "bypass_end_refuse", "actor" => to_string(actor)})
      {:error, :agents_cannot_disable_hard_allow}
    else
      st = load_state() |> Map.put("bypass", nil)
      save_state(st)
      _ = audit(%{"event" => "bypass_end", "actor" => "operator", "bypass" => "operator"})
      :ok
    end
  end

  @doc """
  Permanent disable is never available — even to the operator.
  Use start_bypass/1. Agents always get :agents_cannot_disable_hard_allow.
  """
  def request_disable(actor \\ :agent) do
    _ =
      audit(%{
        "event" => "disable_refuse",
        "actor" => to_string(actor),
        "reason" => if(actor == :operator, do: "use_timed_bypass", else: "agents_cannot_disable_hard_allow")
      })

    if actor == :operator do
      {:error, :use_timed_bypass}
    else
      {:error, :agents_cannot_disable_hard_allow}
    end
  end

  @doc """
  Decide whether an off-allowlist verb may proceed under operator bypass.
  Allowlisted verbs do not need this — CommandFabric already allows them.
  """
  def bypass_covers?(actor, command, host \\ hostname()) do
    actor == :operator && bypass_covers_command?(active_bypass(load_state()), command, host)
  end

  @doc "Record a gate decision (allow / deny / bypass)."
  def record_decision(result, meta) when is_map(meta) do
    event =
      case result do
        :allow -> "allow"
        :deny -> "deny"
        :bypass -> "bypass_allow"
        other -> to_string(other)
      end

    audit(Map.merge(%{"event" => event, "result" => event}, stringify_keys(meta)))
  end

  # ---- internals ----

  defp active_bypass(st) do
    case st["bypass"] do
      %{} = b ->
        case DateTime.from_iso8601(b["expires_at"] || "") do
          {:ok, exp, _} ->
            if DateTime.compare(DateTime.utc_now(), exp) == :lt, do: b, else: nil

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  defp bypass_covers_command?(nil, _command, _host), do: false

  defp bypass_covers_command?(bypass, command, host) do
    hosts = bypass["hosts"] || []
    verbs = bypass["verbs"] || []
    cmd = to_string(command)
    host_ok = hosts == [] or to_string(host) in hosts
    verb_ok = verbs == [] or cmd in verbs
    host_ok and verb_ok
  end

  def hostname do
    case :inet.gethostname() do
      {:ok, h} -> List.to_string(h)
      _ -> "unknown"
    end
  end

  defp load_state do
    path = state_path()

    case File.read(path) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, %{} = map} -> map
          _ -> %{"bypass" => nil}
        end

      _ ->
        %{"bypass" => nil}
    end
  end

  defp save_state(st) do
    path = state_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(st))
  end

  defp state_path do
    System.get_env("MESH_HARD_ALLOW_STATE") ||
      System.get_env("MESH_GATE_STATE") ||
      Path.expand("~/.local/share/mesh/hard_allow.json")
  end

  defp audit(event) when is_map(event) do
    Mesh.Audit.record(Map.put(event, "component", "hard_allow"))
  end

  defp stringify_keys(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end
end
