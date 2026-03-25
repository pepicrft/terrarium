defmodule Terrarium.Providers.LocalTest do
  use ExUnit.Case, async: true

  alias Terrarium.Providers.Local

  describe "create/1" do
    test "creates a sandbox with a temp directory" do
      {:ok, sandbox} = Local.create([])

      assert sandbox.provider == Local
      assert sandbox.state["cwd"]
      assert sandbox.state["temp"] == true
      assert File.dir?(sandbox.state["cwd"])

      Local.destroy(sandbox)
    end

    @tag :tmp_dir
    test "creates a sandbox with a custom cwd", %{tmp_dir: tmp_dir} do
      {:ok, sandbox} = Local.create(cwd: tmp_dir)

      assert sandbox.state["cwd"] == tmp_dir
      assert sandbox.state["temp"] == false

      Local.destroy(sandbox)
      # Custom cwd should not be deleted
      assert File.dir?(tmp_dir)
    end
  end

  describe "destroy/1" do
    test "removes the temp directory" do
      {:ok, sandbox} = Local.create([])
      cwd = sandbox.state["cwd"]
      assert File.dir?(cwd)

      :ok = Local.destroy(sandbox)
      refute File.dir?(cwd)
    end
  end

  describe "status/1" do
    test "always returns :running" do
      {:ok, sandbox} = Local.create([])
      assert :running = Local.status(sandbox)
      Local.destroy(sandbox)
    end
  end

  describe "exec/3" do
    test "executes a shell command" do
      {:ok, sandbox} = Local.create([])

      assert {:ok, result} = Local.exec(sandbox, "echo hello")
      assert result.exit_code == 0
      assert result.stdout == "hello\n"

      Local.destroy(sandbox)
    end

    test "runs in the sandbox cwd by default" do
      {:ok, sandbox} = Local.create([])

      assert {:ok, result} = Local.exec(sandbox, "pwd")
      assert String.trim(result.stdout) |> String.ends_with?(Path.basename(sandbox.state["cwd"]))

      Local.destroy(sandbox)
    end

    test "returns non-zero exit code on failure" do
      {:ok, sandbox} = Local.create([])

      assert {:ok, result} = Local.exec(sandbox, "exit 42")
      assert result.exit_code == 42

      Local.destroy(sandbox)
    end
  end

  describe "read_file/2 and write_file/3" do
    test "writes and reads a file" do
      {:ok, sandbox} = Local.create([])

      :ok = Local.write_file(sandbox, "hello.txt", "world")
      assert {:ok, "world"} = Local.read_file(sandbox, "hello.txt")

      Local.destroy(sandbox)
    end

    test "creates parent directories" do
      {:ok, sandbox} = Local.create([])

      :ok = Local.write_file(sandbox, "a/b/c.txt", "nested")
      assert {:ok, "nested"} = Local.read_file(sandbox, "a/b/c.txt")

      Local.destroy(sandbox)
    end

    test "handles absolute paths" do
      {:ok, sandbox} = Local.create([])
      abs_path = Path.join(sandbox.state["cwd"], "abs_test.txt")

      :ok = Local.write_file(sandbox, abs_path, "absolute")
      assert {:ok, "absolute"} = Local.read_file(sandbox, abs_path)

      Local.destroy(sandbox)
    end

    test "returns error for missing file" do
      {:ok, sandbox} = Local.create([])

      assert {:error, :enoent} = Local.read_file(sandbox, "nope.txt")

      Local.destroy(sandbox)
    end
  end

  describe "ls/2" do
    test "lists directory contents sorted" do
      {:ok, sandbox} = Local.create([])

      Local.write_file(sandbox, "b.txt", "")
      Local.write_file(sandbox, "a.txt", "")

      assert {:ok, ["a.txt", "b.txt"]} = Local.ls(sandbox, ".")

      Local.destroy(sandbox)
    end

    test "returns error for missing directory" do
      {:ok, sandbox} = Local.create([])

      assert {:error, :enoent} = Local.ls(sandbox, "nope")

      Local.destroy(sandbox)
    end
  end

  describe "reconnect/1" do
    test "returns the sandbox as-is" do
      {:ok, sandbox} = Local.create([])
      assert {:ok, ^sandbox} = Local.reconnect(sandbox)
      Local.destroy(sandbox)
    end
  end
end
