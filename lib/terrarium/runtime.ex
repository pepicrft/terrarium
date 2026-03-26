defmodule Terrarium.Runtime do
  @moduledoc false

  alias Terrarium.Sandbox

  require Logger

  @default_dest "/opt/terrarium/release"
  @default_timeout 300_000

  @doc """
  Runs the current BEAM application in the given sandbox.

  Installs a matching Erlang/OTP version, deploys the running node's code,
  and starts a connected peer node over SSH.

  ## Options

  - `:name` — atom name for the remote node (default: `:"terrarium_<sandbox.id>"`)
  - `:env` — environment variables for the remote VM (map)
  - `:erl_args` — additional `erl` arguments as a string
  - `:dest` — remote directory for deployed code (default: `"#{@default_dest}"`)
  - `:timeout` — timeout for Erlang installation in ms (default: `#{@default_timeout}`)

  ## Examples

      {:ok, pid, node} = Terrarium.Runtime.run(sandbox)
      {:ok, pid, node} = Terrarium.Runtime.run(sandbox, env: %{"MIX_ENV" => "prod"})
  """
  @spec run(Sandbox.t(), keyword()) :: {:ok, pid(), node()} | {:error, term()}
  def run(%Sandbox{} = sandbox, opts \\ []) do
    otp_version = :erlang.system_info(:otp_release) |> List.to_string()
    dest = Keyword.get(opts, :dest, @default_dest)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    Logger.info("Starting runtime in sandbox",
      sandbox_id: sandbox.id,
      otp_version: otp_version,
      dest: dest
    )

    :telemetry.span([:terrarium, :replicate], %{sandbox: sandbox, otp_version: otp_version}, fn ->
      with :ok <- ensure_erlang(sandbox, otp_version, timeout),
           :ok <- deploy_code(sandbox, dest),
           {:ok, pid, node} <- start_peer(sandbox, dest, opts) do
        Logger.info("Runtime started in sandbox",
          sandbox_id: sandbox.id,
          node: node,
          otp_version: otp_version
        )

        {{:ok, pid, node}, %{node: node}}
      else
        {:error, reason} = error ->
          Logger.error("Failed to start runtime in sandbox",
            sandbox_id: sandbox.id,
            reason: reason
          )

          {error, %{}}
      end
    end)
  end

  @doc """
  Stops a remote runtime started by `run/2`.

  Terminates the peer node and cleans up resources.

  ## Examples

      :ok = Terrarium.Runtime.stop(pid)
  """
  @spec stop(pid()) :: :ok
  def stop(peer_pid) do
    Terrarium.Peer.stop(peer_pid)
  end

  # ============================================================================
  # Erlang Installation
  # ============================================================================

  defp ensure_erlang(sandbox, otp_version, timeout) do
    case detect_otp_version(sandbox) do
      {:ok, installed} when installed == otp_version ->
        Logger.debug("Erlang #{otp_version} already installed", sandbox_id: sandbox.id)
        :ok

      {:ok, installed} ->
        Logger.info("Erlang version mismatch, installing #{otp_version}",
          sandbox_id: sandbox.id,
          installed_version: installed,
          requested_version: otp_version
        )

        install_erlang(sandbox, otp_version, timeout)

      {:error, :not_installed} ->
        Logger.info("Erlang not found, installing #{otp_version}", sandbox_id: sandbox.id)
        install_erlang(sandbox, otp_version, timeout)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp detect_otp_version(sandbox) do
    cmd = "erl -eval 'io:format(\"~s\", [erlang:system_info(otp_release)]), halt().' -noshell"

    case Terrarium.exec(sandbox, cmd) do
      {:ok, %{exit_code: 0, stdout: version}} -> {:ok, String.trim(version)}
      {:ok, _} -> {:error, :not_installed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp install_erlang(sandbox, otp_version, timeout) do
    with {:ok, strategy} <- detect_install_strategy(sandbox) do
      Logger.info("Installing Erlang #{otp_version} via #{strategy}", sandbox_id: sandbox.id)

      case run_install(sandbox, strategy, otp_version, timeout) do
        :ok ->
          Logger.info("Erlang #{otp_version} installed", sandbox_id: sandbox.id, strategy: strategy)
          :ok

        {:error, reason} = error ->
          Logger.error("Erlang installation failed",
            sandbox_id: sandbox.id,
            strategy: strategy,
            reason: reason
          )

          error
      end
    end
  end

  defp detect_install_strategy(sandbox) do
    cond do
      command_available?(sandbox, "mise") -> {:ok, :mise}
      command_available?(sandbox, "apt-get") -> {:ok, :apt}
      command_available?(sandbox, "apk") -> {:ok, :apk}
      true -> {:error, :no_supported_installer}
    end
  end

  defp command_available?(sandbox, command) do
    match?({:ok, %{exit_code: 0}}, Terrarium.exec(sandbox, "which #{command}"))
  end

  defp run_install(sandbox, :mise, version, timeout) do
    exec_install(sandbox, "mise install erlang@#{version} && mise use --global erlang@#{version}", timeout)
  end

  defp run_install(sandbox, :apt, version, timeout) do
    exec_install(
      sandbox,
      "apt-get update -qq && apt-get install -y -qq erlang-base=1:#{version}* erlang-dev=1:#{version}*",
      timeout
    )
  end

  defp run_install(sandbox, :apk, version, timeout) do
    exec_install(sandbox, "apk add --no-cache erlang~#{version}", timeout)
  end

  defp exec_install(sandbox, command, timeout) do
    case Terrarium.exec(sandbox, command, timeout: timeout) do
      {:ok, %{exit_code: 0}} -> :ok
      {:ok, %{exit_code: code, stderr: stderr}} -> {:error, {:install_failed, code, stderr}}
      {:error, reason} -> {:error, reason}
    end
  end

  # ============================================================================
  # Code Deployment
  # ============================================================================

  defp deploy_code(sandbox, dest) do
    paths =
      :code.get_path()
      |> Enum.map(&List.to_string/1)
      |> Enum.filter(&File.dir?/1)

    Logger.debug("Creating tarball from #{length(paths)} code paths", sandbox_id: sandbox.id)

    case create_tarball(paths) do
      {:ok, tarball_data} ->
        Logger.debug("Tarball created",
          sandbox_id: sandbox.id,
          size_bytes: byte_size(tarball_data)
        )

        upload_and_extract(sandbox, tarball_data, dest)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp upload_and_extract(sandbox, tarball_data, dest) do
    remote_tarball = "#{dest}/deploy.tar.gz"

    with {:ok, %{exit_code: 0}} <- Terrarium.exec(sandbox, "mkdir -p #{dest}"),
         :ok <- Terrarium.write_file(sandbox, remote_tarball, tarball_data),
         {:ok, %{exit_code: 0}} <- Terrarium.exec(sandbox, "tar xzf #{remote_tarball} -C #{dest}"),
         {:ok, %{exit_code: 0}} <- Terrarium.exec(sandbox, "rm -f #{remote_tarball}") do
      Logger.debug("Code deployed to #{dest}", sandbox_id: sandbox.id)
      :ok
    else
      {:ok, %{exit_code: code, stderr: stderr}} -> {:error, {:deploy_failed, code, stderr}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_tarball(paths) do
    tarball_path = Path.join(System.tmp_dir!(), "terrarium_deploy_#{System.unique_integer([:positive])}.tar.gz")
    file_args = Enum.flat_map(paths, fn path -> ["-C", Path.dirname(path), Path.basename(path)] end)

    try do
      case System.cmd("tar", ["czf", tarball_path | file_args], stderr_to_stdout: true) do
        {_, 0} -> File.read(tarball_path)
        {output, _} -> {:error, {:tar_failed, output}}
      end
    after
      File.rm(tarball_path)
    end
  end

  # ============================================================================
  # Peer Node
  # ============================================================================

  defp start_peer(sandbox, dest, opts) do
    peer_opts =
      opts
      |> Keyword.take([:name, :env, :erl_args])
      |> Keyword.put(:pa_paths, ["#{dest}/*/ebin"])

    Terrarium.Peer.start(sandbox, peer_opts)
  end
end
