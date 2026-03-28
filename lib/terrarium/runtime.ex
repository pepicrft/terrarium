defmodule Terrarium.Runtime do
  @moduledoc false

  alias Terrarium.Sandbox

  require Logger

  @default_dest "/opt/terrarium/release"

  @doc """
  Runs the current BEAM application in the given sandbox.

  Ensures `mise` is available in the sandbox, deploys the running node's code,
  and starts a connected peer node over SSH using the host OTP version.

  ## Options

  - `:name` — atom name for the remote node (default: `:"terrarium_<sandbox.id>"`)
  - `:env` — environment variables for the remote VM (map)
  - `:erl_args` — additional `erl` arguments as a string
  - `:dest` — remote directory for deployed code (default: `"#{@default_dest}"`)

  ## Examples

      {:ok, pid, node} = Terrarium.Runtime.run(sandbox)
      {:ok, pid, node} = Terrarium.Runtime.run(sandbox, env: %{"MIX_ENV" => "prod"})
  """
  @spec run(Sandbox.t(), keyword()) :: {:ok, pid(), node()} | {:error, term()}
  def run(%Sandbox{} = sandbox, opts \\ []) do
    otp_version = :erlang.system_info(:otp_release) |> List.to_string()
    dest = Keyword.get(opts, :dest, @default_dest)

    Logger.info("Starting runtime in sandbox",
      sandbox_id: sandbox.id,
      otp_version: otp_version,
      dest: dest
    )

    :telemetry.span([:terrarium, :replicate], %{sandbox: sandbox, otp_version: otp_version}, fn ->
      with :ok <- ensure_mise(sandbox),
           :ok <- deploy_code(sandbox, dest),
           {:ok, pid, node} <- start_peer(sandbox, otp_version, dest, opts) do
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
  # mise
  # ============================================================================

  defp ensure_mise(sandbox) do
    case Terrarium.exec(sandbox, "which mise") do
      {:ok, %{exit_code: 0}} ->
        Logger.debug("mise already available", sandbox_id: sandbox.id)
        :ok

      _ ->
        Logger.info("Installing mise", sandbox_id: sandbox.id)

        case Terrarium.exec(
               sandbox,
               ~s(curl -fsSL https://mise.run | sh),
               timeout: 60_000
             ) do
          {:ok, %{exit_code: 0}} ->
            Logger.info("mise installed", sandbox_id: sandbox.id)
            :ok

          {:ok, %{exit_code: code, stderr: stderr}} ->
            {:error, {:mise_install_failed, code, stderr}}

          {:error, reason} ->
            {:error, reason}
        end
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

  defp start_peer(sandbox, otp_version, dest, opts) do
    peer_opts =
      opts
      |> Keyword.take([:name, :env, :erl_args])
      |> Keyword.put(:pa_paths, ["#{dest}/*/ebin"])
      |> Keyword.put(:erl_cmd, "$HOME/.local/bin/mise x erlang@#{otp_version} -- erl")

    Terrarium.Peer.start(sandbox, peer_opts)
  end
end
