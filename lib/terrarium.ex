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

  Configure a default provider so you don't have to pass it on every call:

      # config/config.exs
      config :terrarium, provider: Terrarium.Providers.Local

      # config/prod.exs
      config :terrarium, provider: Terrarium.Daytona

  ## Usage

      # Using the configured default provider
      {:ok, sandbox} = Terrarium.create(image: "debian:12")

      # Or explicitly passing a provider
      {:ok, sandbox} = Terrarium.create(MyApp.Sandbox.Daytona, image: "debian:12")

      # Execute commands
      {:ok, result} = Terrarium.exec(sandbox, "echo hello")

      # Read and write files
      :ok = Terrarium.write_file(sandbox, "/app/config.exs", content)
      {:ok, content} = Terrarium.read_file(sandbox, "/app/config.exs")

      # Clean up
      :ok = Terrarium.destroy(sandbox)
  """

  alias Terrarium.Sandbox

  @doc """
  Creates a new sandbox using the given provider, or the configured default.

  ## Options

  Options are provider-specific. Common options include:

  - `:image` — the base image for the sandbox
  - `:resources` — CPU, memory, and disk configuration

  ## Examples

      # With configured default provider
      {:ok, sandbox} = Terrarium.create(image: "debian:12")

      # With explicit provider
      {:ok, sandbox} = Terrarium.create(MyProvider, image: "debian:12")
  """
  @spec create(module() | keyword(), keyword()) :: {:ok, Sandbox.t()} | {:error, term()}
  def create(provider_or_opts \\ [], opts \\ [])

  def create(provider, opts) when is_atom(provider) do
    provider.create(opts)
  end

  def create(opts, []) when is_list(opts) do
    {provider, opts} = resolve_provider(opts)
    provider.create(opts)
  end

  @doc """
  Creates a new sandbox, raising on error.
  """
  @spec create!(module() | keyword(), keyword()) :: Sandbox.t()
  def create!(provider_or_opts \\ [], opts \\ [])

  def create!(provider, opts) when is_atom(provider) do
    case create(provider, opts) do
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
    provider.reconnect(sandbox)
  end

  @doc """
  Destroys a sandbox and releases its resources.

  ## Examples

      :ok = Terrarium.destroy(sandbox)
  """
  @spec destroy(Sandbox.t()) :: :ok | {:error, term()}
  def destroy(%Sandbox{provider: provider} = sandbox) do
    provider.destroy(sandbox)
  end

  @doc """
  Returns the current status of a sandbox.

  ## Examples

      status = Terrarium.status(sandbox)
      # => :running
  """
  @spec status(Sandbox.t()) :: Terrarium.Provider.status()
  def status(%Sandbox{provider: provider} = sandbox) do
    provider.status(sandbox)
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
    provider.exec(sandbox, command, opts)
  end

  @doc """
  Reads a file from the sandbox.

  ## Examples

      {:ok, content} = Terrarium.read_file(sandbox, "/app/config.exs")
  """
  @spec read_file(Sandbox.t(), String.t()) :: {:ok, binary()} | {:error, term()}
  def read_file(%Sandbox{provider: provider} = sandbox, path) do
    provider.read_file(sandbox, path)
  end

  @doc """
  Writes content to a file in the sandbox.

  ## Examples

      :ok = Terrarium.write_file(sandbox, "/app/config.exs", content)
  """
  @spec write_file(Sandbox.t(), String.t(), binary()) :: :ok | {:error, term()}
  def write_file(%Sandbox{provider: provider} = sandbox, path, content) do
    provider.write_file(sandbox, path, content)
  end

  @doc """
  Lists the contents of a directory in the sandbox.

  ## Examples

      {:ok, entries} = Terrarium.ls(sandbox, "/app")
  """
  @spec ls(Sandbox.t(), String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def ls(%Sandbox{provider: provider} = sandbox, path) do
    provider.ls(sandbox, path)
  end

  defp resolve_provider(opts) do
    case Keyword.pop(opts, :provider) do
      {nil, opts} ->
        case Application.get_env(:terrarium, :provider) do
          nil ->
            raise ArgumentError,
                  "no default provider configured. Either pass a provider module explicitly " <>
                    "or set one in your config: config :terrarium, provider: Terrarium.Providers.Local"

          provider ->
            {provider, opts}
        end

      {provider, opts} ->
        {provider, opts}
    end
  end
end
