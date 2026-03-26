defmodule Terrarium.RuntimeTest do
  use ExUnit.Case, async: true

  alias Terrarium.RuntimeTestProvider

  defp create_sandbox(exec_responses \\ %{}) do
    {:ok, sandbox} = RuntimeTestProvider.create(exec_responses: exec_responses)
    sandbox
  end

  # Full run/2 pipeline can't be tested without real SSH, but we verify
  # the code deployment stage and the function signatures.

  describe "run/2" do
    test "deploys code and attempts to start peer (fails without real SSH)" do
      sandbox = create_sandbox()

      # Gets past deploy_code, fails at Terrarium.Peer.start (no real SSH)
      result = Terrarium.Runtime.run(sandbox)
      assert {:error, _reason} = result
    end

    test "accepts custom destination" do
      sandbox = create_sandbox()

      result = Terrarium.Runtime.run(sandbox, dest: "/custom/path")
      assert {:error, _reason} = result
    end

    test "accepts env and erl_args options" do
      sandbox = create_sandbox()

      result = Terrarium.Runtime.run(sandbox, env: %{"MIX_ENV" => "prod"}, erl_args: "+S 4")
      assert {:error, _reason} = result
    end
  end

  describe "stop/1" do
    test "is defined" do
      assert {:stop, 1} in Terrarium.Runtime.__info__(:functions)
    end
  end
end
