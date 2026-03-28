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

  @exec_retries 3

  @impl true
  def create(opts) do
    cwd = Keyword.get_lazy(opts, :cwd, &create_temp_dir/0)

    sandbox = %Terrarium.Sandbox{
      id: generate_id(),
      provider: __MODULE__,
      state: %{"cwd" => cwd, "temp" => !Keyword.has_key?(opts, :cwd)}
    }

    {:ok, sandbox}
  end

  @impl true
  def destroy(%Terrarium.Sandbox{state: %{"cwd" => cwd, "temp" => true}}) do
    File.rm_rf!(cwd)
    :ok
  end

  def destroy(_sandbox), do: :ok

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

  def exec(%Terrarium.Sandbox{state: %{"cwd" => cwd}}, command, opts) do
    work_dir = Keyword.get(opts, :cwd, cwd)
    env = Keyword.get(opts, :env, %{}) |> Enum.map(fn {k, v} -> {to_string(k), to_string(v)} end)
    timeout = Keyword.get(opts, :timeout, 120_000)

    exec_with_retries(command, work_dir, env, timeout, @exec_retries)
  end

  defp exec_with_retries(command, work_dir, env, timeout, retries_left) do
    case exec_once_in_worker(command, work_dir, env, timeout) do
      {:retry, reason} ->
        retry_exec(command, work_dir, env, timeout, retries_left, reason)

      result ->
        result
    end
  end

  defp retry_exec(command, work_dir, env, timeout, retries_left, _reason) when retries_left > 0 do
    Process.sleep((@exec_retries - retries_left + 1) * 25)
    exec_with_retries(command, work_dir, env, timeout, retries_left - 1)
  end

  defp retry_exec(_command, _work_dir, _env, _timeout, 0, reason) do
    {:error, {:exec_failed, reason}}
  end

  defp exec_once_in_worker(command, work_dir, env, timeout) do
    parent = self()
    ref = make_ref()

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        send(parent, {ref, exec_once(command, work_dir, env, timeout)})
      end)

    receive do
      {^ref, result} ->
        Process.demonitor(monitor_ref, [:flush])
        result

      {:DOWN, ^monitor_ref, :process, ^pid, reason} when reason in [:epipe, {:epipe, nil}] ->
        {:retry, reason}

      {:DOWN, ^monitor_ref, :process, ^pid, {:epipe, _} = reason} ->
        {:retry, reason}

      {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
        {:error, {:exec_failed, reason}}
    after
      timeout + 1_000 ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^monitor_ref, :process, ^pid, _reason} -> :ok
        after
          0 -> :ok
        end

        {:error, {:timeout, ""}}
    end
  end

  defp exec_once(command, work_dir, env, timeout) do
    case MuonTrap.cmd("/bin/sh", ["-c", command],
           cd: work_dir,
           env: env,
           timeout: timeout,
           stderr_to_stdout: true,
           # Prioritize command latency over throughput for short-lived test commands.
           # This avoids Linux CI flakes where port work can be delayed long enough
           # for ExUnit to time out while waiting on a trivial command like `echo`.
           parallelism: false
         ) do
      {stdout, :timeout} ->
        {:error, {:timeout, stdout}}

      {stdout, exit_code} ->
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
