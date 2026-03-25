defmodule Terrarium.Provider do
  @moduledoc """
  Behaviour for sandbox providers.

  A provider is responsible for the full lifecycle of a sandbox: creating it,
  destroying it, querying its status, and interacting with it (executing commands,
  reading/writing files).

  Providers implement this behaviour to integrate with specific sandbox platforms
  like Daytona, E2B, Modal, Fly Sprites, Namespace, and others.

  ## Implementing a provider

      defmodule MyApp.Sandbox.Daytona do
        @behaviour Terrarium.Provider

        @impl true
        def create(opts) do
          # Call Daytona API to create a sandbox
          {:ok, %Terrarium.Sandbox{id: sandbox_id, provider: __MODULE__, state: %{...}}}
        end

        @impl true
        def destroy(sandbox) do
          # Call Daytona API to destroy the sandbox
          :ok
        end

        # ... implement remaining callbacks
      end

  ## Optional callbacks

  Providers that don't support file operations can skip `read_file/2`, `write_file/3`,
  and `ls/2` — they will return `{:error, :not_supported}` by default.

  All providers must implement `ssh_opts/1` to return SSH connection parameters.
  This enables consumers like Helmsman to establish Erlang distribution over SSH
  for running BEAM nodes inside sandboxes.
  """

  alias Terrarium.Sandbox

  @type status :: :creating | :running | :stopped | :destroyed | :error

  @doc """
  Creates a new sandbox.

  Options are provider-specific. Common options include:

  - `:image` — the base image or template
  - `:resources` — map with `:cpu`, `:memory`, `:disk` keys
  - `:env` — environment variables
  - `:timeout` — creation timeout in milliseconds
  """
  @callback create(opts :: keyword()) :: {:ok, Sandbox.t()} | {:error, term()}

  @doc """
  Destroys a sandbox and releases all associated resources.
  """
  @callback destroy(sandbox :: Sandbox.t()) :: :ok | {:error, term()}

  @doc """
  Returns the current status of a sandbox.
  """
  @callback status(sandbox :: Sandbox.t()) :: status()

  @doc """
  Executes a command in the sandbox.

  ## Options

  - `:cwd` — working directory for the command
  - `:env` — environment variables as a map
  - `:timeout` — timeout in milliseconds
  """
  @callback exec(sandbox :: Sandbox.t(), command :: String.t(), opts :: keyword()) ::
              {:ok, Terrarium.Process.Result.t()} | {:error, term()}

  @doc """
  Reads a file from the sandbox filesystem.
  """
  @callback read_file(sandbox :: Sandbox.t(), path :: String.t()) :: {:ok, binary()} | {:error, term()}

  @doc """
  Writes content to a file in the sandbox filesystem.
  Creates parent directories as needed.
  """
  @callback write_file(sandbox :: Sandbox.t(), path :: String.t(), content :: binary()) :: :ok | {:error, term()}

  @doc """
  Lists the contents of a directory in the sandbox.
  """
  @callback ls(sandbox :: Sandbox.t(), path :: String.t()) :: {:ok, [String.t()]} | {:error, term()}

  @type ssh_opts :: [
          host: String.t(),
          port: non_neg_integer(),
          user: String.t(),
          auth: auth()
        ]

  @type auth ::
          {:password, String.t()}
          | {:key, String.t()}
          | {:key_path, String.t()}
          | {:user_dir, String.t()}
          | nil

  @doc """
  Returns SSH connection parameters for the sandbox.

  Providers must implement this callback to return the host, port, user, and
  authentication details needed to open an SSH connection to the sandbox. This
  is used by consumers that need direct SSH access, for example to establish
  Erlang distribution over SSH using `:peer`.

  ## Return value

  A keyword list with the following keys:

  - `:host` — hostname or IP address
  - `:port` — SSH port (typically 22)
  - `:user` — SSH username
  - `:auth` — authentication method, one of:
    - `{:password, password}` — password authentication
    - `{:key, pem_string}` — PEM-encoded private key
    - `{:key_path, path}` — path to a private key file
    - `{:user_dir, path}` — directory containing SSH keys
    - `nil` — use default key discovery
  """
  @callback ssh_opts(sandbox :: Sandbox.t()) :: {:ok, ssh_opts()} | {:error, term()}

  @doc """
  Reconnects to an existing sandbox after client restart.

  Called with a sandbox struct restored from `Terrarium.Sandbox.from_map/1`.
  The provider should verify the sandbox is still alive and refresh any
  transient state (auth tokens, connections, etc.).

  Returns an updated sandbox on success, or `{:error, :not_found}` if the
  sandbox no longer exists.
  """
  @callback reconnect(sandbox :: Sandbox.t()) :: {:ok, Sandbox.t()} | {:error, term()}

  @doc """
  Transfers a local file to the sandbox filesystem.

  This callback enables providers to implement efficient bulk file transfer
  (e.g., SFTP for SSH providers). The default implementation reads the local
  file and delegates to `write_file/3`.

  ## Options

  - `:timeout` — transfer timeout in milliseconds
  """
  @callback transfer(sandbox :: Sandbox.t(), local_path :: String.t(), remote_path :: String.t(), opts :: keyword()) ::
              :ok | {:error, term()}

  @optional_callbacks [read_file: 2, write_file: 3, ls: 2, transfer: 4]

  @doc false
  defmacro __using__(_opts) do
    quote do
      @behaviour Terrarium.Provider

      @impl true
      def reconnect(%Terrarium.Sandbox{} = sandbox) do
        case status(sandbox) do
          :running -> {:ok, sandbox}
          :creating -> {:ok, sandbox}
          status -> {:error, {:not_running, status}}
        end
      end

      @impl true
      def read_file(_sandbox, _path), do: {:error, :not_supported}

      @impl true
      def write_file(_sandbox, _path, _content), do: {:error, :not_supported}

      @impl true
      def ls(_sandbox, _path), do: {:error, :not_supported}

      @impl true
      def transfer(sandbox, local_path, remote_path, _opts) do
        case File.read(local_path) do
          {:ok, content} -> write_file(sandbox, remote_path, content)
          {:error, reason} -> {:error, reason}
        end
      end

      defoverridable reconnect: 1, read_file: 2, write_file: 3, ls: 2, transfer: 4
    end
  end
end
