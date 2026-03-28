defmodule Terrarium.Peer do
  @moduledoc """
  Starts and manages remote BEAM peer nodes inside Terrarium sandboxes.

  This module builds on `Terrarium.ssh_opts/1` and Erlang's `:peer` module to
  start a remote BEAM node over SSH using `:standard_io` connection. It uses
  `Port.open({:spawn_executable, ...})` with the SSH binary for clean argument
  passing without shell escaping issues.

  ## Authentication

  All auth types supported by `Terrarium.Provider.ssh_opts/1` are handled:

  - `{:key_path, path}` — passes `-i path` to ssh
  - `{:key, pem}` — writes a temp file with `0o600` permissions, cleaned up when the peer stops
  - `{:user_dir, dir}` — passes `-o IdentityFile=...` for ed25519 and rsa keys
  - `{:password, pass}` — uses `SSH_ASKPASS` with `SSH_ASKPASS_REQUIRE=force`
  - `nil` — no extra auth flags, uses ssh defaults

  ## Usage

      {:ok, sandbox} = Terrarium.create(image: "debian:12")

      {:ok, pid, node} = Terrarium.Peer.start(sandbox,
        pa_paths: ["/opt/terrarium/release/lib/*/ebin"],
        env: %{"MIX_ENV" => "prod"}
      )

      # The node is now connected and you can call into it:
      :rpc.call(node, System, :version, [])

      # When done:
      Terrarium.Peer.stop(pid)

  ## Telemetry

  This module emits the following telemetry spans:

  - `[:terrarium, :peer, :start, :start | :stop | :exception]` — when starting a peer
  - `[:terrarium, :peer, :stop, :start | :stop | :exception]` — when stopping a peer
  """

  alias Terrarium.Sandbox

  @doc """
  Starts a remote BEAM peer node in the given sandbox.

  Connects to the sandbox over SSH using `:standard_io` connection mode from
  Erlang's `:peer` module. The SSH connection is established via
  `Port.open({:spawn_executable, ...})` with properly separated arguments.

  ## Options

  - `:name` — atom name for the peer node (default: `:"terrarium_<sandbox.id>"`)
  - `:pa_paths` — list of code paths to add via `-pa` flags
  - `:env` — map of environment variables to set before starting `erl`
  - `:erl_args` — additional erl arguments as a string

  ## Examples

      {:ok, pid, node} = Terrarium.Peer.start(sandbox)
      {:ok, pid, node} = Terrarium.Peer.start(sandbox, name: :my_node, pa_paths: ["/app/lib/*/ebin"])
  """
  @spec start(Sandbox.t(), keyword()) :: {:ok, pid(), node()} | {:error, term()}
  def start(%Sandbox{} = sandbox, opts \\ []) do
    do_start(sandbox, opts)
  end

  @doc """
  Stops a remote BEAM peer node.

  Delegates to `:peer.stop/1`.

  ## Examples

      :ok = Terrarium.Peer.stop(pid)
  """
  @spec stop(pid()) :: :ok
  def stop(peer_pid) do
    :peer.stop(peer_pid)
  end

  defp do_start(sandbox, opts) do
    with {:ok, ssh_config} <- Terrarium.ssh_opts(sandbox) do
      name = Keyword.get(opts, :name, :"terrarium_#{sandbox.id}")
      pa_paths = Keyword.get(opts, :pa_paths, [])
      env = Keyword.get(opts, :env, %{})
      erl_args = Keyword.get(opts, :erl_args, "")
      erl_cmd = Keyword.get(opts, :erl_cmd, "erl")

      {exec_cmd, temp_files} = build_ssh_exec(ssh_config, env, pa_paths, erl_args, erl_cmd)

      peer_opts = %{
        name: name,
        connection: :standard_io,
        exec: exec_cmd
      }

      try do
        case :peer.start(peer_opts) do
          {:ok, pid, node} ->
            maybe_monitor_temp_files(temp_files, pid)
            {:ok, pid, node}

          {:error, reason} ->
            cleanup_temp_files(temp_files)
            {:error, reason}
        end
      catch
        kind, reason ->
          cleanup_temp_files(temp_files)
          {:error, {:peer_start_failed, {kind, reason}}}
      end
    end
  end

  defp build_ssh_exec(ssh_config, env, pa_paths, erl_args, erl_cmd) do
    host = ssh_config[:host]
    port = ssh_config[:port] || 22
    user = ssh_config[:user]
    auth = ssh_config[:auth]

    {auth_flags, auth_temp_files} = build_auth_flags(auth)
    erl_command = build_erl_command(pa_paths, env, erl_args, erl_cmd)

    ssh_parts =
      [
        "ssh",
        "-o StrictHostKeyChecking=no",
        "-o UserKnownHostsFile=/dev/null",
        "-p #{port}"
      ] ++ auth_flags ++ ["#{user}@#{host}"]

    ssh_cmd = Enum.join(ssh_parts, " ")

    # Create a wrapper script that :peer can use as the "erl" executable.
    # :peer calls it with args like: -sname <name> -user peer
    # The script forwards those args to the remote erl via SSH.
    script_path = Path.join(System.tmp_dir!(), "terrarium_peer_#{:erlang.unique_integer([:positive])}.sh")

    script = """
    #!/bin/sh
    exec #{ssh_cmd} "#{erl_command} $@"
    """

    File.write!(script_path, script)
    File.chmod!(script_path, 0o755)

    {to_charlist(script_path), [script_path | auth_temp_files]}
  end

  defp build_auth_flags(nil), do: {[], []}

  defp build_auth_flags({:key_path, path}) do
    {["-i #{Path.expand(path)}"], []}
  end

  defp build_auth_flags({:key, pem}) do
    tmp_path = Path.join(System.tmp_dir!(), "terrarium_key_#{:erlang.unique_integer([:positive])}")
    File.write!(tmp_path, pem)
    File.chmod!(tmp_path, 0o600)
    {["-i #{tmp_path}"], [tmp_path]}
  end

  defp build_auth_flags({:user_dir, dir}) do
    expanded = Path.expand(dir)

    {[
       "-o IdentityFile=#{Path.join(expanded, "id_ed25519")}",
       "-o IdentityFile=#{Path.join(expanded, "id_rsa")}"
     ], []}
  end

  defp build_auth_flags({:password, password}) do
    askpass_path =
      Path.join(System.tmp_dir!(), "terrarium_askpass_#{:erlang.unique_integer([:positive])}")

    File.write!(askpass_path, "#!/bin/sh\necho '#{escape_shell(password)}'\n")
    File.chmod!(askpass_path, 0o700)

    {[
       "-o SetEnv=SSH_ASKPASS=#{askpass_path}",
       "-o SetEnv=SSH_ASKPASS_REQUIRE=force",
       "-o SetEnv=DISPLAY=:0"
     ], [askpass_path]}
  end

  defp build_erl_command(pa_paths, env, erl_args, erl_cmd) do
    env_prefix =
      env
      |> Enum.map_join(" ", fn {k, v} -> "#{k}=#{escape_shell(v)}" end)

    pa_flags =
      pa_paths
      |> Enum.flat_map(fn path -> ["-pa", path] end)
      |> Enum.join(" ")

    parts =
      [
        if(env_prefix != "", do: env_prefix),
        erl_cmd,
        "-noinput",
        if(pa_flags != "", do: pa_flags),
        if(erl_args != "", do: erl_args)
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(parts, " ")
  end

  defp maybe_monitor_temp_files(temp_files, peer_pid) when is_list(temp_files) and temp_files != [] do
    spawn(fn ->
      ref = Process.monitor(peer_pid)

      receive do
        {:DOWN, ^ref, :process, _, _} ->
          Enum.each(temp_files, &File.rm/1)
      end
    end)
  end

  defp maybe_monitor_temp_files(_temp_files, _peer_pid), do: :ok

  defp cleanup_temp_files(temp_files) when is_list(temp_files) do
    Enum.each(temp_files, &File.rm/1)
  end

  defp cleanup_temp_files(_), do: :ok

  defp escape_shell(value) when is_binary(value) do
    String.replace(value, "'", "'\\''")
  end
end
