defmodule Terrarium.Runtime do
  @moduledoc """
  Run the current BEAM application in a remote sandbox.

  This module provides a single high-level primitive: take the running Erlang/OTP
  node, replicate it inside a Terrarium sandbox (same OTP version, same code),
  and return a connected peer node you can call into with `:erpc` or `:rpc`.

  Erlang is installed on-demand via `mise x erlang@<version> -- erl ...`, which
  handles downloading and caching the correct OTP version transparently. The
  sandbox must have `mise` available.

  ## Usage

      {:ok, sandbox} = Terrarium.create(:daytona, api_key: "...")
      {:ok, pid, node} = Terrarium.Runtime.run(sandbox)

      # Call into the remote node
      :erpc.call(node, MyModule, :my_function, [args])

      # When done
      :ok = Terrarium.Runtime.stop(pid)
      :ok = Terrarium.destroy(sandbox)

  ## What `run/2` does

  1. Detects the local OTP version from the running VM
  2. Tarballs the current node's BEAM files and deploys them
  3. Starts a remote peer node via SSH, using `mise x erlang@<version>` to
     ensure the correct Erlang version is available (installed on first use)
  4. Returns `{:ok, peer_pid, node}` with a connected node

  ## Options

  - `:name` — atom name for the remote node (default: `:"terrarium_<sandbox.id>"`)
  - `:env` — environment variables for the remote VM (map)
  - `:erl_args` — additional `erl` arguments as a string
  - `:dest` — remote directory for deployed code (default: `"/opt/terrarium/release"`)
  """

  alias Terrarium.Sandbox

  require Logger

  @default_dest "/opt/terrarium/release"

  @doc """
  Runs the current BEAM application in the given sandbox.

  Deploys the running node's code and starts a connected peer node over SSH.
  Erlang is provided via `mise x erlang@<version>`, which installs the correct
  version on first use.

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

    :telemetry.span([:terrarium, :runtime, :run], %{sandbox: sandbox, otp_version: otp_version}, fn ->
      with :ok <- deploy_code(sandbox, dest),
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
      |> Keyword.put(:erl_cmd, "mise x erlang@#{otp_version} -- erl")

    Terrarium.Peer.start(sandbox, peer_opts)
  end
end
