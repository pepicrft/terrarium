defmodule Terrarium do
  @moduledoc """
  An Elixir abstraction for provisioning and interacting with sandbox environments.

  Terrarium provides a common interface for working with sandbox providers like
  Daytona, E2B, Modal, Fly Sprites, and others. It separates the concerns of
  provisioning (creating/destroying environments) from interaction (executing
  commands, reading/writing files).

  ## Architecture

  Terrarium defines a single `Terrarium.Provider` behaviour that covers lifecycle
  management, command execution, and file operations. Providers implement this
  behaviour to integrate with platforms like Daytona, E2B, Modal, Fly Sprites, and others.

  ## Configuration

  Configure multiple providers and set a default:

      config :terrarium,
        default: :daytona,
        providers: [
          daytona: {Terrarium.Daytona, api_key: System.fetch_env!("DAYTONA_API_KEY")},
          e2b: {Terrarium.E2B, api_key: System.fetch_env!("E2B_API_KEY")},
          local: Terrarium.Providers.Local
        ]

  ## Usage

      # Uses the default provider
      {:ok, sandbox} = Terrarium.create(image: "debian:12")

      # Uses a named provider
      {:ok, sandbox} = Terrarium.create(:e2b, image: "debian:12")

      # Uses an explicit provider module
      {:ok, sandbox} = Terrarium.create(Terrarium.Daytona, image: "debian:12", api_key: "...")

      # Execute commands
      {:ok, result} = Terrarium.exec(sandbox, "echo hello")

      # Read and write files
      :ok = Terrarium.write_file(sandbox, "/app/config.exs", content)
      {:ok, content} = Terrarium.read_file(sandbox, "/app/config.exs")

      # Clean up
      :ok = Terrarium.destroy(sandbox)
  """

  alias Terrarium.Sandbox

  require Logger

  @doc """
  Creates a new sandbox.

  Can be called in three ways:

  - `Terrarium.create(opts)` — uses the configured default provider
  - `Terrarium.create(:name, opts)` — uses a named provider from config
  - `Terrarium.create(ProviderModule, opts)` — uses the module directly

  Provider-specific options from config are merged with call-site opts,
  with call-site opts taking precedence.

  ## Options

  Options are provider-specific. Common options include:

  - `:image` — the base image for the sandbox
  - `:resources` — CPU, memory, and disk configuration
  - `:provider` — inline provider as a module or `{module, opts}` tuple

  ## Examples

      {:ok, sandbox} = Terrarium.create(image: "debian:12")
      {:ok, sandbox} = Terrarium.create(:e2b, image: "debian:12")
      {:ok, sandbox} = Terrarium.create(MyProvider, image: "debian:12")
  """
  @spec create(module() | atom() | keyword(), keyword()) :: {:ok, Sandbox.t()} | {:error, term()}
  def create(provider_or_opts \\ [], opts \\ [])

  def create(name, opts) when is_atom(name) and name != nil do
    {config, opts} = Keyword.pop(opts, :config)
    {provider, provider_opts} = resolve_named_or_module(name, config)
    Logger.debug("Creating sandbox", provider: provider)

    Terrarium.Telemetry.span(:create, %{provider: provider}, fn ->
      case provider.create(Keyword.merge(provider_opts, opts)) do
        {:ok, sandbox} = result ->
          Logger.info("Sandbox created", sandbox_id: sandbox.id, provider: provider)
          result

        {:error, reason} = error ->
          Logger.error("Failed to create sandbox", provider: provider, reason: reason)
          error
      end
    end)
  end

  def create(opts, []) when is_list(opts) do
    {config, opts} = Keyword.pop(opts, :config)
    {provider, provider_opts, opts} = resolve_from_opts(opts, config)
    Logger.debug("Creating sandbox", provider: provider)

    Terrarium.Telemetry.span(:create, %{provider: provider}, fn ->
      case provider.create(Keyword.merge(provider_opts, opts)) do
        {:ok, sandbox} = result ->
          Logger.info("Sandbox created", sandbox_id: sandbox.id, provider: provider)
          result

        {:error, reason} = error ->
          Logger.error("Failed to create sandbox", provider: provider, reason: reason)
          error
      end
    end)
  end

  @doc """
  Creates a new sandbox, raising on error.
  """
  @spec create!(module() | atom() | keyword(), keyword()) :: Sandbox.t()
  def create!(provider_or_opts \\ [], opts \\ [])

  def create!(name, opts) when is_atom(name) and name != nil do
    case create(name, opts) do
      {:ok, sandbox} -> sandbox
      {:error, reason} -> raise "Failed to create sandbox: #{inspect(reason)}"
    end
  end

  def create!(opts, []) when is_list(opts) do
    case create(opts) do
      {:ok, sandbox} -> sandbox
      {:error, reason} -> raise "Failed to create sandbox: #{inspect(reason)}"
    end
  end

  @doc """
  Reconnects to an existing sandbox after client restart.

  Use this after restoring a sandbox from `Terrarium.Sandbox.from_map/1` to
  verify the sandbox is still alive and refresh any transient state.

  ## Examples

      data = MyStore.load("sandbox-123")
      sandbox = Terrarium.Sandbox.from_map(data)
      {:ok, sandbox} = Terrarium.reconnect(sandbox)
  """
  @spec reconnect(Sandbox.t()) :: {:ok, Sandbox.t()} | {:error, term()}
  def reconnect(%Sandbox{provider: provider} = sandbox) do
    Logger.debug("Reconnecting to sandbox", sandbox_id: sandbox.id, provider: provider)

    Terrarium.Telemetry.span(:reconnect, %{sandbox: sandbox}, fn ->
      case provider.reconnect(sandbox) do
        {:ok, sandbox} = result ->
          Logger.info("Reconnected to sandbox", sandbox_id: sandbox.id, provider: provider)
          result

        {:error, reason} = error ->
          Logger.error("Failed to reconnect to sandbox",
            sandbox_id: sandbox.id,
            provider: provider,
            reason: reason
          )

          error
      end
    end)
  end

  @doc """
  Destroys a sandbox and releases its resources.

  ## Examples

      :ok = Terrarium.destroy(sandbox)
  """
  @spec destroy(Sandbox.t()) :: :ok | {:error, term()}
  def destroy(%Sandbox{provider: provider} = sandbox) do
    Logger.debug("Destroying sandbox", sandbox_id: sandbox.id, provider: provider)

    Terrarium.Telemetry.span(:destroy, %{sandbox: sandbox}, fn ->
      case provider.destroy(sandbox) do
        :ok ->
          Logger.info("Sandbox destroyed", sandbox_id: sandbox.id, provider: provider)
          :ok

        {:error, reason} = error ->
          Logger.error("Failed to destroy sandbox",
            sandbox_id: sandbox.id,
            provider: provider,
            reason: reason
          )

          error
      end
    end)
  end

  @doc """
  Returns the current status of a sandbox.

  ## Examples

      status = Terrarium.status(sandbox)
      # => :running
  """
  @spec status(Sandbox.t()) :: Terrarium.Provider.status()
  def status(%Sandbox{provider: provider} = sandbox) do
    Logger.debug("Checking sandbox status", sandbox_id: sandbox.id, provider: provider)

    Terrarium.Telemetry.span(:status, %{sandbox: sandbox}, fn ->
      status = provider.status(sandbox)
      Logger.debug("Sandbox status retrieved", sandbox_id: sandbox.id, status: status)
      status
    end)
  end

  @doc """
  Executes a command in the sandbox.

  ## Options

  - `:cwd` — working directory for the command
  - `:env` — environment variables as a map
  - `:timeout` — timeout in milliseconds

  ## Examples

      {:ok, result} = Terrarium.exec(sandbox, "ls -la")
      result.stdout
  """
  @spec exec(Sandbox.t(), String.t(), keyword()) :: {:ok, Terrarium.Process.Result.t()} | {:error, term()}
  def exec(%Sandbox{provider: provider} = sandbox, command, opts \\ []) do
    Logger.debug("Executing command",
      sandbox_id: sandbox.id,
      command: command,
      cwd: Keyword.get(opts, :cwd)
    )

    Terrarium.Telemetry.span(:exec, %{sandbox: sandbox, command: command}, fn ->
      case provider.exec(sandbox, command, opts) do
        {:ok, result} = ok ->
          Logger.debug("Command completed",
            sandbox_id: sandbox.id,
            command: command,
            exit_code: result.exit_code
          )

          ok

        {:error, reason} = error ->
          Logger.error("Command failed",
            sandbox_id: sandbox.id,
            command: command,
            reason: reason
          )

          error
      end
    end)
  end

  @doc """
  Reads a file from the sandbox.

  ## Examples

      {:ok, content} = Terrarium.read_file(sandbox, "/app/config.exs")
  """
  @spec read_file(Sandbox.t(), String.t()) :: {:ok, binary()} | {:error, term()}
  def read_file(%Sandbox{provider: provider} = sandbox, path) do
    Logger.debug("Reading file", sandbox_id: sandbox.id, path: path)

    Terrarium.Telemetry.span(:read_file, %{sandbox: sandbox, path: path}, fn ->
      case provider.read_file(sandbox, path) do
        {:ok, content} = result ->
          Logger.debug("File read", sandbox_id: sandbox.id, path: path, size: byte_size(content))
          result

        {:error, reason} = error ->
          Logger.error("Failed to read file", sandbox_id: sandbox.id, path: path, reason: reason)
          error
      end
    end)
  end

  @doc """
  Writes content to a file in the sandbox.

  ## Examples

      :ok = Terrarium.write_file(sandbox, "/app/config.exs", content)
  """
  @spec write_file(Sandbox.t(), String.t(), binary()) :: :ok | {:error, term()}
  def write_file(%Sandbox{provider: provider} = sandbox, path, content) do
    Logger.debug("Writing file", sandbox_id: sandbox.id, path: path, size: byte_size(content))

    Terrarium.Telemetry.span(:write_file, %{sandbox: sandbox, path: path}, fn ->
      case provider.write_file(sandbox, path, content) do
        :ok ->
          Logger.debug("File written", sandbox_id: sandbox.id, path: path)
          :ok

        {:error, reason} = error ->
          Logger.error("Failed to write file",
            sandbox_id: sandbox.id,
            path: path,
            reason: reason
          )

          error
      end
    end)
  end

  @doc """
  Returns SSH connection parameters for the sandbox.

  This allows consumers to establish direct SSH connections to the sandbox,
  for example to set up Erlang distribution using `:peer` or to tunnel
  other protocols over SSH.

  ## Examples

      {:ok, opts} = Terrarium.ssh_opts(sandbox)
      # opts = [host: "sandbox.example.com", port: 22, user: "root", auth: nil]
  """
  @spec ssh_opts(Sandbox.t()) :: {:ok, Terrarium.Provider.ssh_opts()} | {:error, term()}
  def ssh_opts(%Sandbox{provider: provider} = sandbox) do
    Logger.debug("Retrieving SSH opts", sandbox_id: sandbox.id, provider: provider)

    Terrarium.Telemetry.span(:ssh_opts, %{sandbox: sandbox}, fn ->
      case provider.ssh_opts(sandbox) do
        {:ok, opts} = result ->
          Logger.debug("SSH opts retrieved",
            sandbox_id: sandbox.id,
            ssh_host: opts[:host],
            ssh_port: opts[:port],
            ssh_user: opts[:user]
          )

          result

        {:error, reason} = error ->
          Logger.error("Failed to retrieve SSH opts",
            sandbox_id: sandbox.id,
            provider: provider,
            reason: reason
          )

          error
      end
    end)
  end

  @doc """
  Lists the contents of a directory in the sandbox.

  ## Examples

      {:ok, entries} = Terrarium.ls(sandbox, "/app")
  """
  @spec ls(Sandbox.t(), String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def ls(%Sandbox{provider: provider} = sandbox, path) do
    Logger.debug("Listing directory", sandbox_id: sandbox.id, path: path)

    Terrarium.Telemetry.span(:ls, %{sandbox: sandbox, path: path}, fn ->
      case provider.ls(sandbox, path) do
        {:ok, entries} = result ->
          Logger.debug("Directory listed",
            sandbox_id: sandbox.id,
            path: path,
            entry_count: length(entries)
          )

          result

        {:error, reason} = error ->
          Logger.error("Failed to list directory",
            sandbox_id: sandbox.id,
            path: path,
            reason: reason
          )

          error
      end
    end)
  end

  defp get_config(nil, key, default), do: Application.get_env(:terrarium, key, default)
  defp get_config(config, key, default), do: Keyword.get(config, key, default)

  # Resolves an atom that could be either a named provider from config
  # or a direct provider module.
  defp resolve_named_or_module(name, config) do
    providers = get_config(config, :providers, [])

    case Keyword.fetch(providers, name) do
      {:ok, {module, opts}} -> {module, opts}
      {:ok, module} when is_atom(module) -> {module, []}
      :error -> {name, []}
    end
  end

  # Resolves the provider from opts (inline :provider key) or falls back
  # to the configured default.
  defp resolve_from_opts(opts, config) do
    case Keyword.pop(opts, :provider) do
      {nil, opts} ->
        {provider, provider_opts} = resolve_default!(config)
        {provider, provider_opts, opts}

      {{module, provider_opts}, opts} when is_atom(module) ->
        {module, provider_opts, opts}

      {module, opts} when is_atom(module) ->
        {provider, provider_opts} = resolve_named_or_module(module, config)
        {provider, provider_opts, opts}
    end
  end

  defp resolve_default!(config) do
    case get_config(config, :default, nil) do
      nil ->
        raise ArgumentError,
              "no default provider configured. Either pass a provider explicitly " <>
                "or configure one: config :terrarium, default: :local, providers: [local: Terrarium.Providers.Local]"

      name ->
        resolve_named_or_module(name, config)
    end
  end
end
