# Terrarium

[![Hex.pm](https://img.shields.io/hexpm/v/terrarium.svg)](https://hex.pm/packages/terrarium)
[![HexDocs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/terrarium)
[![CI](https://github.com/pepicrft/terrarium/actions/workflows/terrarium.yml/badge.svg)](https://github.com/pepicrft/terrarium/actions/workflows/terrarium.yml)

An Elixir abstraction for provisioning and interacting with sandbox environments.

## Motivation

The AI agent ecosystem is producing many sandbox environment providers - Daytona, E2B, Modal, Fly Sprites, Namespace, and more. Each has its own API, SDK, and conventions. Terrarium provides a common Elixir interface so your code doesn't couple to any single provider.

## Features

- **Provider behaviour** - a single contract for creating, destroying, and querying sandbox environments
- **Process execution** - run commands in sandboxes with structured results
- **File operations** - read, write, and list files within sandboxes
- **Named providers** - configure multiple providers with their credentials, pick a default
- **Local provider** - built-in provider for dev/test that runs everything on the local machine
- **Serialization** - persist and restore sandbox references across client restarts
- **Provider-agnostic** - swap providers without changing application code
- **Replication** - replicate the current BEAM application (OTP version + code) into a sandbox and get a connected peer node

## Installation

Add `terrarium` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:terrarium, "~> 0.2.0"}
  ]
end
```

## Configuration

Configure multiple providers and set a default, similar to Finch pools:

```elixir
# config/runtime.exs
config :terrarium,
  default: :daytona,
  providers: [
    daytona: {Terrarium.Daytona, api_key: System.fetch_env!("DAYTONA_API_KEY"), region: "us"},
    e2b: {Terrarium.E2B, api_key: System.fetch_env!("E2B_API_KEY")},
    local: Terrarium.Providers.Local
  ]
```

Connect to an existing machine via SSH:

```elixir
config :terrarium,
  default: :server,
  providers: [
    server: {Terrarium.Providers.SSH,
      host: "dev.example.com",
      user: "deploy",
      auth: {:key, System.fetch_env!("SSH_PRIVATE_KEY")}
    }
  ]
```

For development, use the built-in local provider:

```elixir
# config/dev.exs
config :terrarium,
  default: :local,
  providers: [
    local: Terrarium.Providers.Local
  ]
```

## Quick Start

### 1. Add a provider package

```elixir
def deps do
  [
    {:terrarium, "~> 0.2.0"},
    {:terrarium_daytona, "~> 0.1.0"}
  ]
end
```

### 2. Create and use a sandbox

```elixir
# Uses the configured default provider
{:ok, sandbox} = Terrarium.create(image: "debian:12")

# Or use a specific named provider
{:ok, sandbox} = Terrarium.create(:e2b, image: "debian:12")

# Or pass a provider module directly
{:ok, sandbox} = Terrarium.create(Terrarium.Daytona, image: "debian:12", api_key: "...")

# Execute commands
{:ok, result} = Terrarium.exec(sandbox, "echo hello")
IO.puts(result.stdout)

# File operations
:ok = Terrarium.write_file(sandbox, "/app/hello.txt", "Hello from Terrarium!")
{:ok, content} = Terrarium.read_file(sandbox, "/app/hello.txt")

# Clean up
:ok = Terrarium.destroy(sandbox)
```

### 3. Surviving client restarts

Sandboxes can be serialized and restored if the client process restarts while the remote sandbox is still running:

```elixir
# Persist before shutdown
data = Terrarium.Sandbox.to_map(sandbox)
MyStore.save("sandbox-123", data)

# Restore after restart
data = MyStore.load("sandbox-123")
sandbox = Terrarium.Sandbox.from_map(data)
{:ok, sandbox} = Terrarium.reconnect(sandbox)
```

## Implementing a Provider

Providers implement the `Terrarium.Provider` behaviour:

```elixir
defmodule MyProvider do
  use Terrarium.Provider

  @impl true
  def create(opts) do
    # Provision a sandbox via your provider's API
    {:ok, %Terrarium.Sandbox{id: id, provider: __MODULE__, state: %{...}}}
  end

  @impl true
  def destroy(sandbox) do
    # Tear down the sandbox
    :ok
  end

  @impl true
  def status(sandbox) do
    :running
  end

  @impl true
  def reconnect(sandbox) do
    # Verify the sandbox is still alive, refresh tokens, etc.
    {:ok, sandbox}
  end

  @impl true
  def exec(sandbox, command, opts) do
    # Execute the command
    {:ok, %Terrarium.Process.Result{exit_code: 0, stdout: output}}
  end

  # File operations are optional - defaults return {:error, :not_supported}
  @impl true
  def read_file(sandbox, path) do
    {:ok, content}
  end

  @impl true
  def write_file(sandbox, path, content) do
    :ok
  end
end
```

## Available Providers

| Provider | Package | Status |
|---|---|---|
| Local | `terrarium` (built-in) | Available |
| SSH | `terrarium` (built-in) | Available |
| [Daytona](https://daytona.io) | `terrarium_daytona` | Planned |
| [E2B](https://e2b.dev) | `terrarium_e2b` | Planned |
| [Modal](https://modal.com) | `terrarium_modal` | Planned |
| [Fly Sprites](https://sprites.dev) | `terrarium_sprites` | Planned |
| [Namespace](https://namespace.so) | `terrarium_namespace` | Planned |

## Replication

Replicate the current BEAM application into a sandbox with a single call. `Terrarium.replicate/2` detects the local OTP version, installs a matching Erlang in the sandbox, deploys the running node's code, and starts a connected peer:

```elixir
{:ok, sandbox} = Terrarium.create(image: "debian:12")
{:ok, pid, node} = Terrarium.replicate(sandbox)

# Call your own modules on the remote node
:erpc.call(node, MyModule, :my_function, [args])

# Clean up
Terrarium.stop_replica(pid)
Terrarium.destroy(sandbox)
```

Options: `:name`, `:env`, `:erl_args`, `:dest` (remote deploy path), `:timeout` (Erlang install timeout).

## Telemetry

Terrarium emits telemetry events for all operations via `:telemetry.span/3`. Each operation emits `:start`, `:stop`, and `:exception` events automatically.

| Event | Metadata |
|---|---|
| `[:terrarium, :create, *]` | `%{provider: module}` |
| `[:terrarium, :destroy, *]` | `%{sandbox: sandbox}` |
| `[:terrarium, :exec, *]` | `%{sandbox: sandbox, command: string}` |
| `[:terrarium, :read_file, *]` | `%{sandbox: sandbox, path: string}` |
| `[:terrarium, :write_file, *]` | `%{sandbox: sandbox, path: string}` |
| `[:terrarium, :ls, *]` | `%{sandbox: sandbox, path: string}` |
| `[:terrarium, :reconnect, *]` | `%{sandbox: sandbox}` |
| `[:terrarium, :status, *]` | `%{sandbox: sandbox}` |
| `[:terrarium, :ssh_opts, *]` | `%{sandbox: sandbox}` |
| `[:terrarium, :replicate, *]` | `%{sandbox: sandbox, otp_version: string}` |

```elixir
:telemetry.attach_many(
  "terrarium-logger",
  [
    [:terrarium, :create, :stop],
    [:terrarium, :exec, :stop],
    [:terrarium, :destroy, :stop]
  ],
  fn event, measurements, metadata, _config ->
    Logger.info("#{inspect(event)} took #{measurements.duration} native time units")
  end,
  nil
)
```

## License

This project is licensed under the [MIT License](LICENSE).
