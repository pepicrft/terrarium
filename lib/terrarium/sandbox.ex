defmodule Terrarium.Sandbox do
  @moduledoc """
  Represents a running sandbox environment.

  A sandbox is the core data structure in Terrarium. It carries the provider module
  that created it along with provider-specific state needed to interact with the
  sandbox (IDs, connection info, credentials, etc.).

  You should not construct this struct directly — it is returned by `Terrarium.create/2`.

  ## Serialization

  Sandboxes can be serialized to a map and restored later, which is useful when
  the client process restarts but the remote sandbox is still running:

      # Persist before shutdown
      data = Terrarium.Sandbox.to_map(sandbox)
      MyStore.save("sandbox-123", data)

      # Restore after restart
      data = MyStore.load("sandbox-123")
      sandbox = Terrarium.Sandbox.from_map(data)
      {:ok, sandbox} = Terrarium.reconnect(sandbox)
  """

  @type t :: %__MODULE__{
          id: String.t(),
          provider: module(),
          name: String.t() | nil,
          state: map()
        }

  @derive {JSON.Encoder, only: [:id, :provider, :name, :state]}
  @enforce_keys [:id, :provider]
  defstruct [:id, :provider, :name, state: %{}]

  @doc """
  Serializes a sandbox to a plain map suitable for persistence.

  The resulting map can be encoded to JSON, stored in a database,
  or serialized with `:erlang.term_to_binary/1`.

  ## Examples

      iex> sandbox = %Terrarium.Sandbox{id: "abc", provider: MyProvider, state: %{"token" => "xyz"}}
      iex> Terrarium.Sandbox.to_map(sandbox)
      %{"id" => "abc", "provider" => "Elixir.MyProvider", "name" => nil, "state" => %{"token" => "xyz"}}
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{id: id, provider: provider, name: name, state: state}) do
    %{
      "id" => id,
      "provider" => Atom.to_string(provider),
      "name" => name,
      "state" => state
    }
  end

  @doc """
  Restores a sandbox from a previously serialized map.

  This reconstructs the struct but does not verify the sandbox is still alive.
  Call `Terrarium.reconnect/1` after restoring to validate and refresh the connection.

  ## Examples

      iex> data = %{"id" => "abc", "provider" => "Elixir.MyProvider", "state" => %{"token" => "xyz"}}
      iex> Terrarium.Sandbox.from_map(data)
      %Terrarium.Sandbox{id: "abc", provider: MyProvider, state: %{"token" => "xyz"}}
  """
  @spec from_map(map()) :: t()
  def from_map(%{"id" => id, "provider" => provider, "state" => state} = data) do
    %__MODULE__{
      id: id,
      provider: String.to_existing_atom(provider),
      name: Map.get(data, "name"),
      state: state
    }
  end
end
