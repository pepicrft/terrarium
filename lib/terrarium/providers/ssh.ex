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
            port: 22,
            user_dir: "~/.ssh"
          }
        ]

  ## Options

  - `:host` — (required) hostname or IP address
  - `:user` — (required) SSH username
  - `:port` — SSH port (default: `22`)
  - `:password` — password for authentication
  - `:user_dir` — directory containing SSH keys (default: `~/.ssh`)
  - `:connect_timeout` — connection timeout in milliseconds (default: `10_000`)
  - `:cwd` — default working directory on the remote host (default: `"/"`)

  ## Authentication

  Supports password and key-based authentication. For key-based auth, place
  your keys (`id_rsa`, `id_ed25519`, etc.) in the `:user_dir` directory.
  The `:ssh` module discovers them automatically.
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

    ssh_opts =
      [
        user: to_charlist(user),
        silently_accept_hosts: true,
        user_interaction: false
      ]
      |> maybe_add(:password, opts)
      |> maybe_add(:user_dir, opts)

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
      create(
        host: state["host"],
        user: state["user"],
        port: state["port"],
        cwd: state["cwd"]
      )
    end
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

  defp maybe_add(ssh_opts, :password, opts) do
    case Keyword.fetch(opts, :password) do
      {:ok, password} -> Keyword.put(ssh_opts, :password, to_charlist(password))
      :error -> ssh_opts
    end
  end

  defp maybe_add(ssh_opts, :user_dir, opts) do
    case Keyword.fetch(opts, :user_dir) do
      {:ok, dir} -> Keyword.put(ssh_opts, :user_dir, to_charlist(Path.expand(dir)))
      :error -> ssh_opts
    end
  end
end
