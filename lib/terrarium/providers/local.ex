defmodule Terrarium.Providers.Local do
  @moduledoc """
  A provider that executes everything on the local machine.

  Useful for development and testing where you don't need a remote sandbox.
  Each sandbox gets its own temporary working directory that is cleaned up
  on destroy.

  ## Configuration

      config :terrarium, provider: Terrarium.Providers.Local

  ## Options

  - `:cwd` — working directory for the sandbox (default: creates a temp directory)
  """

  use Terrarium.Provider

  require Logger

  @impl true
  def create(opts) do
    cwd = Keyword.get_lazy(opts, :cwd, &create_temp_dir/0)
    temp = !Keyword.has_key?(opts, :cwd)

    sandbox = %Terrarium.Sandbox{
      id: generate_id(),
      provider: __MODULE__,
      state: %{"cwd" => cwd, "temp" => temp}
    }

    Logger.info("Local sandbox created", sandbox_id: sandbox.id, cwd: cwd, temp: temp)

    {:ok, sandbox}
  end

  @impl true
  def destroy(%Terrarium.Sandbox{state: %{"cwd" => cwd, "temp" => true}} = sandbox) do
    Logger.debug("Removing temp directory", sandbox_id: sandbox.id, cwd: cwd)
    File.rm_rf!(cwd)
    Logger.info("Local sandbox destroyed", sandbox_id: sandbox.id)
    :ok
  end

  def destroy(sandbox) do
    Logger.info("Local sandbox destroyed (cwd preserved)", sandbox_id: sandbox.id)
    :ok
  end

  @impl true
  def status(_sandbox), do: :running

  @impl true
  def reconnect(sandbox), do: {:ok, sandbox}

  @impl true
  def ssh_opts(_sandbox) do
    {:ok, [host: "localhost", port: 22, user: current_user(), auth: nil]}
  end

  @impl true
  def exec(sandbox, command, opts \\ [])

  def exec(%Terrarium.Sandbox{state: %{"cwd" => cwd}} = sandbox, command, opts) do
    work_dir = Keyword.get(opts, :cwd, cwd)
    env = Keyword.get(opts, :env, %{}) |> Enum.map(fn {k, v} -> {to_string(k), to_string(v)} end)
    timeout = Keyword.get(opts, :timeout, 120_000)

    Logger.debug("Executing local command", sandbox_id: sandbox.id, command: command, cwd: work_dir)

    case MuonTrap.cmd("sh", ["-c", command], cd: work_dir, env: env, timeout: timeout) do
      {stdout, :timeout} ->
        Logger.error("Local command timed out",
          sandbox_id: sandbox.id,
          command: command,
          timeout: timeout
        )

        {:error, {:timeout, stdout}}

      {stdout, exit_code} ->
        Logger.debug("Local command completed",
          sandbox_id: sandbox.id,
          command: command,
          exit_code: exit_code
        )

        {:ok, %Terrarium.Process.Result{exit_code: exit_code, stdout: stdout}}
    end
  end

  @impl true
  def read_file(%Terrarium.Sandbox{state: %{"cwd" => cwd}}, path) do
    full_path = resolve_path(cwd, path)

    case File.read(full_path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def write_file(%Terrarium.Sandbox{state: %{"cwd" => cwd}}, path, content) do
    full_path = resolve_path(cwd, path)
    full_path |> Path.dirname() |> File.mkdir_p!()
    File.write(full_path, content)
  end

  @impl true
  def ls(%Terrarium.Sandbox{state: %{"cwd" => cwd}}, path) do
    full_path = resolve_path(cwd, path)

    case File.ls(full_path) do
      {:ok, entries} -> {:ok, Enum.sort(entries)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_path(_cwd, "/" <> _ = absolute_path), do: absolute_path
  defp resolve_path(cwd, relative_path), do: Path.join(cwd, relative_path)

  defp create_temp_dir do
    dir = Path.join(System.tmp_dir!(), "terrarium-#{generate_id()}")
    File.mkdir_p!(dir)
    dir
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end

  defp current_user do
    System.get_env("USER") || System.get_env("USERNAME") || "root"
  end
end
