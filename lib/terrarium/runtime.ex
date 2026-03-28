defmodule Terrarium.Runtime do
  @moduledoc false

  alias Terrarium.Sandbox

  require Logger

  @default_dest ".terrarium/release"

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
           {:ok, dest} <- resolve_dest(sandbox, dest),
           {:ok, erl_path} <- install_erlang(sandbox, otp_version),
           :ok <- deploy_code(sandbox, dest),
           {:ok, pid, node} <- start_peer(sandbox, erl_path, dest, opts) do
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
  # Path Resolution
  # ============================================================================

  defp resolve_dest(sandbox, dest) do
    if String.starts_with?(dest, "/") do
      {:ok, dest}
    else
      case Terrarium.exec(sandbox, "echo $HOME") do
        {:ok, %{exit_code: 0, stdout: home}} ->
          {:ok, Path.join(String.trim(home), dest)}

        _ ->
          # Fallback to /tmp if we can't determine home
          {:ok, Path.join("/tmp", dest)}
      end
    end
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
  # Erlang Installation
  # ============================================================================

  defp install_erlang(sandbox, otp_version) do
    remote_home = resolve_remote_home(sandbox)
    mise = "#{remote_home}/.local/bin/mise"

    Logger.info("Installing Erlang #{otp_version} via mise", sandbox_id: sandbox.id)

    case Terrarium.exec(sandbox, "#{mise} install erlang@#{otp_version}", timeout: 600_000) do
      {:ok, %{exit_code: 0}} ->
        # Get the install path to find the erl binary
        case Terrarium.exec(sandbox, "#{mise} where erlang@#{otp_version}") do
          {:ok, %{exit_code: 0, stdout: path}} ->
            erl_path = Path.join(String.trim(path), "bin/erl")
            Logger.info("Erlang #{otp_version} ready", sandbox_id: sandbox.id, erl_path: erl_path)
            {:ok, erl_path}

          {:ok, %{exit_code: code, stderr: stderr}} ->
            {:error, {:mise_where_failed, code, stderr}}

          {:error, reason} ->
            {:error, reason}
        end

      {:ok, %{exit_code: code, stderr: stderr}} ->
        Logger.error("Erlang installation failed", sandbox_id: sandbox.id, reason: stderr)
        {:error, {:erlang_install_failed, code, stderr}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_remote_home(sandbox) do
    case Terrarium.exec(sandbox, "echo $HOME") do
      {:ok, %{exit_code: 0, stdout: home}} -> String.trim(home)
      _ -> "/root"
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

    tarball_path = Path.join(System.tmp_dir!(), "terrarium_deploy_#{System.unique_integer([:positive])}.tar.gz")
    file_args = Enum.flat_map(paths, fn path -> ["-C", Path.dirname(path), Path.basename(path)] end)

    try do
      case System.cmd("tar", ["czf", tarball_path | file_args], stderr_to_stdout: true) do
        {_, 0} ->
          Logger.debug("Tarball created",
            sandbox_id: sandbox.id,
            size_bytes: File.stat!(tarball_path).size
          )

          remote_tarball = "#{dest}/deploy.tar.gz"

          with {:ok, %{exit_code: 0}} <- Terrarium.exec(sandbox, "mkdir -p #{dest}"),
               :ok <- Terrarium.transfer(sandbox, tarball_path, remote_tarball),
               {:ok, %{exit_code: 0}} <- Terrarium.exec(sandbox, "tar xzf #{remote_tarball} -C #{dest}"),
               {:ok, %{exit_code: 0}} <- Terrarium.exec(sandbox, "rm -f #{remote_tarball}") do
            Logger.debug("Code deployed to #{dest}", sandbox_id: sandbox.id)
            :ok
          else
            {:ok, %{exit_code: code, stderr: stderr}} -> {:error, {:deploy_failed, code, stderr}}
            {:error, reason} -> {:error, reason}
          end

        {output, _} ->
          {:error, {:tar_failed, output}}
      end
    after
      File.rm(tarball_path)
    end
  end

  # ============================================================================
  # Peer Node
  # ============================================================================

  defp start_peer(sandbox, erl_path, dest, opts) do
    peer_opts =
      opts
      |> Keyword.take([:name, :env, :erl_args])
      |> Keyword.put(:pa_paths, ["#{dest}/ebin"])
      |> Keyword.put(:erl_cmd, erl_path)

    Terrarium.Peer.start(sandbox, peer_opts)
  end
end
