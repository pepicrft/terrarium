defmodule TerrariumTest do
  use ExUnit.Case, async: true

  alias Terrarium.Sandbox

  describe "create/2 with explicit module" do
    test "delegates to the provider's create callback" do
      assert {:ok, %Sandbox{id: "test-123", provider: Terrarium.TestProvider}} =
               Terrarium.create(Terrarium.TestProvider)
    end
  end

  describe "create/1 with inline :provider option" do
    test "accepts a provider module in opts" do
      assert {:ok, %Sandbox{provider: Terrarium.TestProvider}} =
               Terrarium.create(provider: Terrarium.TestProvider)
    end

    test "accepts a {module, opts} tuple in opts" do
      assert {:ok, %Sandbox{provider: Terrarium.TestProvider}} =
               Terrarium.create(provider: {Terrarium.TestProvider, some: "config"})
    end
  end

  describe "create/1 with no provider" do
    test "raises when no default is configured" do
      assert_raise ArgumentError, ~r/no default provider configured/, fn ->
        Terrarium.create()
      end
    end
  end

  describe "destroy/1" do
    test "delegates to the provider's destroy callback" do
      sandbox = %Sandbox{id: "test-123", provider: Terrarium.TestProvider}
      assert :ok = Terrarium.destroy(sandbox)
    end
  end

  describe "status/1" do
    test "delegates to the provider's status callback" do
      sandbox = %Sandbox{id: "test-123", provider: Terrarium.TestProvider}
      assert :running = Terrarium.status(sandbox)
    end
  end

  describe "exec/3" do
    test "delegates to the provider's exec callback" do
      sandbox = %Sandbox{id: "test-123", provider: Terrarium.TestProvider}

      assert {:ok, %Terrarium.Process.Result{exit_code: 0, stdout: "hello\n"}} =
               Terrarium.exec(sandbox, "echo hello")
    end
  end

  describe "read_file/2" do
    test "delegates to the provider's read_file callback" do
      sandbox = %Sandbox{id: "test-123", provider: Terrarium.TestProvider}
      assert {:ok, "file content"} = Terrarium.read_file(sandbox, "/app/file.txt")
    end
  end

  describe "write_file/3" do
    test "delegates to the provider's write_file callback" do
      sandbox = %Sandbox{id: "test-123", provider: Terrarium.TestProvider}
      assert :ok = Terrarium.write_file(sandbox, "/app/file.txt", "content")
    end
  end

  describe "ls/2" do
    test "delegates to the provider's ls callback" do
      sandbox = %Sandbox{id: "test-123", provider: Terrarium.TestProvider}
      assert {:ok, ["file1.txt", "file2.txt"]} = Terrarium.ls(sandbox, "/app")
    end
  end

  describe "ssh_opts/1" do
    test "delegates to the provider's ssh_opts callback" do
      sandbox = %Sandbox{id: "test-123", provider: Terrarium.TestProvider}

      assert {:ok, [host: "test.example.com", port: 22, user: "root", auth: nil]} =
               Terrarium.ssh_opts(sandbox)
    end
  end

  describe "reconnect/1" do
    test "delegates to the provider's reconnect callback" do
      sandbox = %Sandbox{id: "test-123", provider: Terrarium.TestProvider}
      assert {:ok, %Sandbox{id: "test-123"}} = Terrarium.reconnect(sandbox)
    end
  end

  describe "Sandbox serialization" do
    test "to_map/1 serializes sandbox to a plain map" do
      sandbox = %Sandbox{id: "test-123", provider: Terrarium.TestProvider, state: %{"token" => "abc"}}
      map = Sandbox.to_map(sandbox)

      assert map == %{
               "id" => "test-123",
               "provider" => "Elixir.Terrarium.TestProvider",
               "name" => nil,
               "state" => %{"token" => "abc"}
             }
    end

    test "from_map/1 restores a sandbox from a serialized map" do
      map = %{
        "id" => "test-123",
        "provider" => "Elixir.Terrarium.TestProvider",
        "state" => %{"token" => "abc"}
      }

      sandbox = Sandbox.from_map(map)

      assert sandbox.id == "test-123"
      assert sandbox.provider == Terrarium.TestProvider
      assert sandbox.state == %{"token" => "abc"}
    end

    test "roundtrip serialization preserves the sandbox" do
      original = %Sandbox{id: "test-123", provider: Terrarium.TestProvider, state: %{"key" => "value"}}
      restored = original |> Sandbox.to_map() |> Sandbox.from_map()

      assert restored.id == original.id
      assert restored.provider == original.provider
      assert restored.state == original.state
    end
  end
end
