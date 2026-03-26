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

  @ssh_base_args [
    ~c"-o",
    ~c"StrictHostKeyChecking=no",
    ~c"-o",
    ~c"UserKnownHostsFile=/dev/null"
  ]

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

  @doc """
  Exec callback invoked by `:peer` to open the SSH port.

  Returns a port connected to the SSH process with properly separated arguments.
  This function is not intended to be called directly.
  """
  @spec peer_exec(map()) :: port()
  def peer_exec(exec_info) do
    %{executable: executable, args: args} = exec_info
    port_opts = [:binary, :stream, :use_stdio, :exit_status, args: args]

    port_opts =
      case Map.get(exec_info, :env) do
        nil -> port_opts
        env -> [{:env, env} | port_opts]
      end

    Port.open({:spawn_executable, executable}, port_opts)
  end

  defp do_start(sandbox, opts) do
    with {:ok, ssh_config} <- Terrarium.ssh_opts(sandbox) do
      name = Keyword.get(opts, :name, :"terrarium_#{sandbox.id}")
      pa_paths = Keyword.get(opts, :pa_paths, [])
      env = Keyword.get(opts, :env, %{})
      erl_args = Keyword.get(opts, :erl_args, "")

      {:ok, exec_info} = build_exec_info(ssh_config, env, pa_paths, erl_args)

      peer_opts = %{
        name: name,
        connection: :standard_io,
        exec: {Terrarium.Peer, :peer_exec, [exec_info]}
      }

      try do
        case :peer.start(peer_opts) do
          {:ok, pid, node} ->
            maybe_monitor_temp_files(exec_info, pid)
            {:ok, pid, node}

          {:error, reason} ->
            cleanup_temp_files(exec_info)
            {:error, reason}
        end
      rescue
        e ->
          cleanup_temp_files(exec_info)
          {:error, {:peer_start_failed, Exception.message(e)}}
      end
    end
  end

  defp build_exec_info(ssh_config, env, pa_paths, erl_args) do
    host = ssh_config[:host]
    port = ssh_config[:port] || 22
    user = ssh_config[:user]
    auth = ssh_config[:auth]

    {:ok, auth_info} = build_auth(auth)

    erl_cmd = build_erl_command(pa_paths, env, erl_args)

    ssh_args =
      @ssh_base_args ++
        [~c"-p", to_charlist(Integer.to_string(port))] ++
        auth_info.args ++
        [to_charlist("#{user}@#{host}")] ++
        [to_charlist(erl_cmd)]

    executable = auth_info.executable
    port_env = Map.get(auth_info, :env)
    temp_files = Map.get(auth_info, :temp_files, [])

    exec_info = %{
      executable: executable,
      args: ssh_args,
      temp_files: temp_files
    }

    exec_info = if port_env, do: Map.put(exec_info, :env, port_env), else: exec_info

    {:ok, exec_info}
  end

  defp build_auth(nil) do
    ssh_path = :os.find_executable(~c"ssh") || raise "ssh not found in PATH"
    {:ok, %{executable: ssh_path, args: []}}
  end

  defp build_auth({:key_path, path}) do
    ssh_path = :os.find_executable(~c"ssh") || raise "ssh not found in PATH"
    {:ok, %{executable: ssh_path, args: [~c"-i", to_charlist(path)]}}
  end

  defp build_auth({:key, pem}) do
    ssh_path = :os.find_executable(~c"ssh") || raise "ssh not found in PATH"
    tmp_path = Path.join(System.tmp_dir!(), "terrarium_key_#{:erlang.unique_integer([:positive])}")
    File.write!(tmp_path, pem)
    File.chmod!(tmp_path, 0o600)

    {:ok,
     %{
       executable: ssh_path,
       args: [~c"-i", to_charlist(tmp_path)],
       temp_files: [tmp_path]
     }}
  end

  defp build_auth({:user_dir, dir}) do
    ssh_path = :os.find_executable(~c"ssh") || raise "ssh not found in PATH"
    expanded = Path.expand(dir)

    {:ok,
     %{
       executable: ssh_path,
       args: [
         ~c"-o",
         to_charlist("IdentityFile=#{Path.join(expanded, "id_ed25519")}"),
         ~c"-o",
         to_charlist("IdentityFile=#{Path.join(expanded, "id_rsa")}")
       ]
     }}
  end

  defp build_auth({:password, password}) do
    ssh_path = :os.find_executable(~c"ssh") || raise "ssh not found in PATH"

    askpass_path =
      Path.join(System.tmp_dir!(), "terrarium_askpass_#{:erlang.unique_integer([:positive])}")

    File.write!(askpass_path, "#!/bin/sh\necho '#{escape_shell(password)}'\n")
    File.chmod!(askpass_path, 0o700)

    {:ok,
     %{
       executable: ssh_path,
       args: [],
       env: [
         {~c"SSH_ASKPASS", to_charlist(askpass_path)},
         {~c"SSH_ASKPASS_REQUIRE", ~c"force"},
         {~c"DISPLAY", ~c":0"}
       ],
       temp_files: [askpass_path]
     }}
  end

  defp build_erl_command(pa_paths, env, erl_args) do
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
        "erl",
        "-noinput",
        if(pa_flags != "", do: pa_flags),
        if(erl_args != "", do: erl_args)
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(parts, " ")
  end

  defp maybe_monitor_temp_files(%{temp_files: temp_files}, peer_pid) when is_list(temp_files) and temp_files != [] do
    spawn(fn ->
      ref = Process.monitor(peer_pid)

      receive do
        {:DOWN, ^ref, :process, _, _} ->
          Enum.each(temp_files, &File.rm/1)
      end
    end)
  end

  defp maybe_monitor_temp_files(_exec_info, _peer_pid), do: :ok

  defp cleanup_temp_files(%{temp_files: temp_files}) when is_list(temp_files) do
    Enum.each(temp_files, &File.rm/1)
  end

  defp cleanup_temp_files(_exec_info), do: :ok

  defp escape_shell(value) when is_binary(value) do
    String.replace(value, "'", "'\\''")
  end
end
