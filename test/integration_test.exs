defmodule Terrarium.IntegrationTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  defp create_sandbox(%{tmp_dir: tmp_dir}) do
    {:ok, sandbox} = Terrarium.create(Terrarium.Providers.Local, cwd: tmp_dir)
    sandbox
  end

  describe "create and destroy" do
    test "creates a sandbox scoped to the test directory", ctx do
      sandbox = create_sandbox(ctx)

      assert sandbox.provider == Terrarium.Providers.Local
      assert sandbox.state["cwd"] == ctx.tmp_dir
      assert :running = Terrarium.status(sandbox)

      :ok = Terrarium.destroy(sandbox)
      # Custom cwd is preserved after destroy
      assert File.dir?(ctx.tmp_dir)
    end
  end

  describe "exec" do
    test "runs a command in the sandbox directory", ctx do
      sandbox = create_sandbox(ctx)

      {:ok, result} = Terrarium.exec(sandbox, "echo hello")
      assert String.trim(result.stdout) == "hello"
      assert result.exit_code == 0
    end

    test "passes environment variables", ctx do
      sandbox = create_sandbox(ctx)

      {:ok, result} = Terrarium.exec(sandbox, "printenv MY_VAR", env: %{"MY_VAR" => "hello"})
      assert String.trim(result.stdout) == "hello"
    end

    test "returns non-zero exit code on failure", ctx do
      sandbox = create_sandbox(ctx)

      {:ok, result} = Terrarium.exec(sandbox, "exit 1")
      assert result.exit_code == 1
    end
  end

  describe "file operations" do
    test "write, read, and list files", ctx do
      sandbox = create_sandbox(ctx)

      :ok = Terrarium.write_file(sandbox, "hello.txt", "world")
      assert {:ok, "world"} = Terrarium.read_file(sandbox, "hello.txt")
      assert {:ok, entries} = Terrarium.ls(sandbox, ".")
      assert "hello.txt" in entries
    end

    test "creates nested directories when writing", ctx do
      sandbox = create_sandbox(ctx)

      :ok = Terrarium.write_file(sandbox, "a/b/c.txt", "nested")
      assert {:ok, "nested"} = Terrarium.read_file(sandbox, "a/b/c.txt")
    end

    test "returns error for missing file", ctx do
      sandbox = create_sandbox(ctx)
      assert {:error, :enoent} = Terrarium.read_file(sandbox, "missing.txt")
    end
  end

  describe "reconnect" do
    test "returns the same sandbox", ctx do
      sandbox = create_sandbox(ctx)
      assert {:ok, ^sandbox} = Terrarium.reconnect(sandbox)
    end
  end
end
