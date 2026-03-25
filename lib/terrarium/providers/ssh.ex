defmodule Terrarium.Providers.SSH do
  @moduledoc """
  A provider that connects to an existing machine via SSH.

  Uses Erlang's built-in `:ssh` and `:ssh_sftp` modules for command execution
  and file operations. The SSH connection is established on `create/1` and
  stored in the sandbox state for reuse across operations.

  ## Configuration

      config :terrarium,
        providers: [
          server: {Terrarium.Providers.SSH,
            host: "dev.example.com",
            user: "deploy",
            auth: {:key_path, "~/.ssh/id_ed25519"}
          }
        ]

  ## Options

  - `:host` — (required) hostname or IP address
  - `:user` — (required) SSH username
  - `:port` — SSH port (default: `22`)
  - `:auth` — authentication method (see below)
  - `:connect_timeout` — connection timeout in milliseconds (default: `10_000`)
  - `:cwd` — default working directory on the remote host (default: `"/"`)

  ## Authentication

  The `:auth` option accepts a tuple specifying the method:

  - `{:password, "secret"}` — password authentication
  - `{:key, pem_string}` — private key as a PEM string (e.g., from an env var)
  - `{:key_path, "~/.ssh/id_ed25519"}` — path to a specific private key file
  - `{:user_dir, "~/.ssh"}` — directory containing SSH keys (auto-discovers)

  If `:auth` is not provided, Erlang's `:ssh` will attempt default key discovery.

  ### Examples

      # Password auth
      {Terrarium.Providers.SSH, host: "example.com", user: "deploy", auth: {:password, "secret"}}

      # Key from a file
      {Terrarium.Providers.SSH, host: "example.com", user: "deploy", auth: {:key_path, "~/.ssh/id_ed25519"}}

      # Key from an environment variable
      {Terrarium.Providers.SSH, host: "example.com", user: "deploy", auth: {:key, System.fetch_env!("SSH_PRIVATE_KEY")}}
  """

  use Terrarium.Provider

  @default_port 22
  @default_connect_timeout 10_000
  @default_exec_timeout 120_000

  @impl true
  def create(opts) do
    host = Keyword.fetch!(opts, :host)
    user = Keyword.fetch!(opts, :user)
    port = Keyword.get(opts, :port, @default_port)
    connect_timeout = Keyword.get(opts, :connect_timeout, @default_connect_timeout)
    cwd = Keyword.get(opts, :cwd, "/")
    auth = Keyword.get(opts, :auth)

    ssh_opts =
      [
        user: to_charlist(user),
        silently_accept_hosts: true,
        user_interaction: false
      ]
      |> add_auth_opts(auth)

    case :ssh.connect(to_charlist(host), port, ssh_opts, connect_timeout) do
      {:ok, conn} ->
        sandbox = %Terrarium.Sandbox{
          id: "ssh-#{host}-#{port}",
          provider: __MODULE__,
          state: %{
            "host" => host,
            "user" => user,
            "port" => port,
            "cwd" => cwd,
            "auth" => serialize_auth(auth),
            "conn" => conn
          }
        }

        {:ok, sandbox}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def destroy(%Terrarium.Sandbox{state: %{"conn" => conn}}) do
    :ssh.close(conn)
    :ok
  end

  @impl true
  def status(%Terrarium.Sandbox{state: %{"conn" => conn}}) do
    if Process.alive?(conn), do: :running, else: :stopped
  end

  @impl true
  def reconnect(%Terrarium.Sandbox{state: state} = sandbox) do
    conn = state["conn"]

    if Process.alive?(conn) do
      {:ok, sandbox}
    else
      # Re-establish connection using stored info
      opts = [
        host: state["host"],
        user: state["user"],
        port: state["port"],
        cwd: state["cwd"]
      ]

      opts =
        case deserialize_auth(state["auth"]) do
          nil -> opts
          auth -> Keyword.put(opts, :auth, auth)
        end

      create(opts)
    end
  end

  @impl true
  def ssh_opts(%Terrarium.Sandbox{state: state}) do
    {:ok,
     [
       host: state["host"],
       port: state["port"],
       user: state["user"],
       auth: deserialize_auth(state["auth"])
     ]}
  end

  @impl true
  def exec(sandbox, command, opts \\ [])

  def exec(%Terrarium.Sandbox{state: %{"conn" => conn, "cwd" => cwd}}, command, opts) do
    work_dir = Keyword.get(opts, :cwd, cwd)
    timeout = Keyword.get(opts, :timeout, @default_exec_timeout)

    full_command = "cd #{escape(work_dir)} && #{command}"

    case :ssh_connection.session_channel(conn, timeout) do
      {:ok, channel} ->
        :success = :ssh_connection.exec(conn, channel, to_charlist(full_command), timeout)
        collect_response(conn, channel, timeout)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def read_file(%Terrarium.Sandbox{state: %{"conn" => conn}}, path) do
    case :ssh_sftp.start_channel(conn) do
      {:ok, sftp} ->
        result = :ssh_sftp.read_file(sftp, to_charlist(path))
        :ssh_sftp.stop_channel(sftp)
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def write_file(%Terrarium.Sandbox{state: %{"conn" => conn}}, path, content) do
    case :ssh_sftp.start_channel(conn) do
      {:ok, sftp} ->
        ensure_remote_dir(sftp, Path.dirname(path))
        result = :ssh_sftp.write_file(sftp, to_charlist(path), content)
        :ssh_sftp.stop_channel(sftp)
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def transfer(%Terrarium.Sandbox{state: %{"conn" => conn}}, local_path, remote_path, _opts) do
    case File.read(local_path) do
      {:ok, content} ->
        case :ssh_sftp.start_channel(conn) do
          {:ok, sftp} ->
            ensure_remote_dir(sftp, Path.dirname(remote_path))
            result = :ssh_sftp.write_file(sftp, to_charlist(remote_path), content)
            :ssh_sftp.stop_channel(sftp)
            result

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def ls(%Terrarium.Sandbox{state: %{"conn" => conn}}, path) do
    case :ssh_sftp.start_channel(conn) do
      {:ok, sftp} ->
        result =
          case :ssh_sftp.list_dir(sftp, to_charlist(path)) do
            {:ok, entries} ->
              names =
                entries
                |> Enum.map(&to_string/1)
                |> Enum.reject(&(&1 in [".", ".."]))
                |> Enum.sort()

              {:ok, names}

            {:error, reason} ->
              {:error, reason}
          end

        :ssh_sftp.stop_channel(sftp)
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp collect_response(conn, channel, timeout) do
    collect_response(conn, channel, timeout, %{stdout: "", stderr: "", exit_status: 0})
  end

  defp collect_response(conn, channel, timeout, acc) do
    receive do
      {:ssh_cm, ^conn, {:data, ^channel, 0, data}} ->
        collect_response(conn, channel, timeout, %{acc | stdout: acc.stdout <> data})

      {:ssh_cm, ^conn, {:data, ^channel, 1, data}} ->
        collect_response(conn, channel, timeout, %{acc | stderr: acc.stderr <> data})

      {:ssh_cm, ^conn, {:eof, ^channel}} ->
        collect_response(conn, channel, timeout, acc)

      {:ssh_cm, ^conn, {:exit_status, ^channel, status}} ->
        collect_response(conn, channel, timeout, %{acc | exit_status: status})

      {:ssh_cm, ^conn, {:closed, ^channel}} ->
        {:ok,
         %Terrarium.Process.Result{
           exit_code: acc.exit_status,
           stdout: acc.stdout,
           stderr: acc.stderr
         }}
    after
      timeout -> {:error, :timeout}
    end
  end

  defp ensure_remote_dir(sftp, path) do
    parts = Path.split(path)

    Enum.reduce(parts, "", fn part, acc ->
      dir = Path.join(acc, part)
      :ssh_sftp.make_dir(sftp, to_charlist(dir))
      dir
    end)
  end

  defp escape(str), do: "'#{String.replace(str, "'", "'\\''")}'"

  defp serialize_auth(nil), do: nil
  defp serialize_auth({:password, password}), do: %{"type" => "password", "value" => password}
  defp serialize_auth({:key, pem}), do: %{"type" => "key", "value" => pem}
  defp serialize_auth({:key_path, path}), do: %{"type" => "key_path", "value" => path}
  defp serialize_auth({:user_dir, dir}), do: %{"type" => "user_dir", "value" => dir}

  defp deserialize_auth(nil), do: nil
  defp deserialize_auth(%{"type" => "password", "value" => v}), do: {:password, v}
  defp deserialize_auth(%{"type" => "key", "value" => v}), do: {:key, v}
  defp deserialize_auth(%{"type" => "key_path", "value" => v}), do: {:key_path, v}
  defp deserialize_auth(%{"type" => "user_dir", "value" => v}), do: {:user_dir, v}

  defp add_auth_opts(ssh_opts, nil), do: ssh_opts

  defp add_auth_opts(ssh_opts, {:password, password}), do: Keyword.put(ssh_opts, :password, to_charlist(password))

  defp add_auth_opts(ssh_opts, {:key, pem}),
    do: Keyword.put(ssh_opts, :key_cb, {Terrarium.Providers.SSH.KeyCb, key: pem})

  defp add_auth_opts(ssh_opts, {:key_path, path}),
    do: Keyword.put(ssh_opts, :key_cb, {Terrarium.Providers.SSH.KeyCb, key_path: path})

  defp add_auth_opts(ssh_opts, {:user_dir, dir}), do: Keyword.put(ssh_opts, :user_dir, to_charlist(Path.expand(dir)))
end
