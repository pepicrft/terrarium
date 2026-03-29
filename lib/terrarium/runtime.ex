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
           {:ok, runtime} <- install_erlang(sandbox, otp_version),
           :ok <- deploy_code(sandbox, dest),
           {:ok, pid, node} <- start_peer(sandbox, runtime, dest, opts) do
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
    elixir_version = System.version()

    Logger.info("Installing Erlang #{otp_version} and Elixir #{elixir_version} via mise",
      sandbox_id: sandbox.id
    )

    install_cmd = "#{mise} install erlang@#{otp_version} elixir@#{elixir_version}"

    case Terrarium.exec(sandbox, install_cmd, timeout: 600_000) do
      {:ok, %{exit_code: 0}} ->
        with {:ok, %{exit_code: 0, stdout: erl_where}} <-
               Terrarium.exec(sandbox, "#{mise} where erlang@#{otp_version}"),
             {:ok, %{exit_code: 0, stdout: elixir_where}} <-
               Terrarium.exec(sandbox, "#{mise} where elixir@#{elixir_version}") do
          erl_path = Path.join(String.trim(erl_where), "bin/erl")
          elixir_lib = Path.join(String.trim(elixir_where), "lib")

          Logger.info("Runtime ready",
            sandbox_id: sandbox.id,
            erl_path: erl_path,
            elixir_lib: elixir_lib
          )

          {:ok, %{erl_path: erl_path, elixir_lib: elixir_lib}}
        else
          {:ok, %{exit_code: code, stderr: stderr}} -> {:error, {:mise_where_failed, code, stderr}}
          {:error, reason} -> {:error, reason}
        end

      {:ok, %{exit_code: code, stderr: stderr}} ->
        Logger.error("Installation failed", sandbox_id: sandbox.id, reason: stderr)
        {:error, {:install_failed, code, stderr}}

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
    # Only deploy application code paths, not OTP or Elixir stdlib.
    # Those are already available on the remote via mise.
    # Include both ebin/ and priv/ directories (priv contains data files
    # needed by some deps like llm_db).
    otp_lib = :code.lib_dir() |> List.to_string()
    elixir_lib = :code.lib_dir(:elixir) |> List.to_string() |> Path.dirname()

    ebin_paths =
      :code.get_path()
      |> Enum.map(&List.to_string/1)
      |> Enum.filter(&File.dir?/1)
      |> Enum.reject(fn p ->
        String.starts_with?(p, otp_lib) or String.starts_with?(p, elixir_lib)
      end)

    # Deploy entire app directories (app-version/) to preserve the ebin/priv structure.
    # This allows Application.app_dir/1 to find priv/ directories on the remote.
    app_dirs =
      ebin_paths
      |> Enum.map(&Path.dirname/1)
      |> Enum.uniq()

    Logger.debug("Creating tarball from #{length(app_dirs)} app dirs", sandbox_id: sandbox.id)

    tarball_path = Path.join(System.tmp_dir!(), "terrarium_deploy_#{System.unique_integer([:positive])}.tar.gz")
    file_args = Enum.flat_map(app_dirs, fn dir -> ["-C", Path.dirname(dir), Path.basename(dir)] end)

    try do
      case System.cmd("tar", ["czf", tarball_path | file_args], stderr_to_stdout: true) do
        {_, 0} ->
          Logger.debug("Tarball created",
            sandbox_id: sandbox.id,
            size_bytes: File.stat!(tarball_path).size
          )

          remote_tarball = "#{dest}/deploy.tar.gz"

          with {:ok, %{exit_code: 0}} <- Terrarium.exec(sandbox, "rm -rf #{dest} && mkdir -p #{dest}"),
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

  defp start_peer(sandbox, runtime, dest, opts) do
    # Include app code + Elixir stdlib paths
    pa_paths = [
      "#{dest}/*/ebin",
      "#{runtime.elixir_lib}/*/ebin"
    ]

    peer_opts =
      opts
      |> Keyword.take([:name, :env, :erl_args])
      |> Keyword.put(:pa_paths, pa_paths)
      |> Keyword.put(:erl_cmd, runtime.erl_path)

    Terrarium.Peer.start(sandbox, peer_opts)
  end
end
