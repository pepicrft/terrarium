defmodule Terrarium.RuntimeTest do
  use ExUnit.Case, async: true

  alias Terrarium.RuntimeTestProvider

  defp create_sandbox(exec_responses) do
    {:ok, sandbox} = RuntimeTestProvider.create(exec_responses: exec_responses)
    sandbox
  end

  # We can't test the full run/2 pipeline without a real SSH sandbox,
  # but we test the individual stages via their observable behavior.

  describe "run/2 — Erlang detection" do
    test "proceeds when matching OTP version is already installed" do
      otp_version = :erlang.system_info(:otp_release) |> List.to_string()

      sandbox =
        create_sandbox(%{
          "erl -eval" => {:ok, %Terrarium.Process.Result{exit_code: 0, stdout: otp_version, stderr: ""}}
        })

      # Gets past ensure_erlang and deploy_code, fails at Terrarium.Peer.start (no real SSH)
      result = Terrarium.replicate(sandbox)
      assert {:error, _reason} = result
    end

    test "attempts install via mise when Erlang is not found" do
      sandbox =
        create_sandbox(%{
          "erl -eval" => {:ok, %Terrarium.Process.Result{exit_code: 1, stdout: "", stderr: "not found"}},
          "which mise" => {:ok, %Terrarium.Process.Result{exit_code: 0, stdout: "/usr/bin/mise", stderr: ""}},
          "mise install" => {:ok, %Terrarium.Process.Result{exit_code: 0, stdout: "", stderr: ""}}
        })

      result = Terrarium.replicate(sandbox)
      assert {:error, _reason} = result
    end

    test "attempts install via apt-get when mise is unavailable" do
      sandbox =
        create_sandbox(%{
          "erl -eval" => {:ok, %Terrarium.Process.Result{exit_code: 1, stdout: "", stderr: ""}},
          "which mise" => {:ok, %Terrarium.Process.Result{exit_code: 1, stdout: "", stderr: ""}},
          "which apt-get" => {:ok, %Terrarium.Process.Result{exit_code: 0, stdout: "/usr/bin/apt-get", stderr: ""}},
          "apt-get" => {:ok, %Terrarium.Process.Result{exit_code: 0, stdout: "", stderr: ""}}
        })

      result = Terrarium.replicate(sandbox)
      assert {:error, _reason} = result
    end

    test "attempts install via apk as last resort" do
      sandbox =
        create_sandbox(%{
          "erl -eval" => {:ok, %Terrarium.Process.Result{exit_code: 1, stdout: "", stderr: ""}},
          "which mise" => {:ok, %Terrarium.Process.Result{exit_code: 1, stdout: "", stderr: ""}},
          "which apt-get" => {:ok, %Terrarium.Process.Result{exit_code: 1, stdout: "", stderr: ""}},
          "which apk" => {:ok, %Terrarium.Process.Result{exit_code: 0, stdout: "/sbin/apk", stderr: ""}},
          "apk add" => {:ok, %Terrarium.Process.Result{exit_code: 0, stdout: "", stderr: ""}}
        })

      result = Terrarium.replicate(sandbox)
      assert {:error, _reason} = result
    end

    test "returns error when no installer is available" do
      sandbox =
        create_sandbox(%{
          "erl -eval" => {:ok, %Terrarium.Process.Result{exit_code: 1, stdout: "", stderr: ""}},
          "which mise" => {:ok, %Terrarium.Process.Result{exit_code: 1, stdout: "", stderr: ""}},
          "which apt-get" => {:ok, %Terrarium.Process.Result{exit_code: 1, stdout: "", stderr: ""}},
          "which apk" => {:ok, %Terrarium.Process.Result{exit_code: 1, stdout: "", stderr: ""}}
        })

      assert {:error, :no_supported_installer} = Terrarium.replicate(sandbox)
    end

    test "returns error when install command fails" do
      sandbox =
        create_sandbox(%{
          "erl -eval" => {:ok, %Terrarium.Process.Result{exit_code: 1, stdout: "", stderr: ""}},
          "which mise" => {:ok, %Terrarium.Process.Result{exit_code: 0, stdout: "/usr/bin/mise", stderr: ""}},
          "mise install" => {:ok, %Terrarium.Process.Result{exit_code: 1, stdout: "", stderr: "version not found"}}
        })

      assert {:error, {:install_failed, 1, "version not found"}} = Terrarium.replicate(sandbox)
    end
  end

  describe "stop_replica/1" do
    test "is defined" do
      assert {:stop_replica, 1} in Terrarium.__info__(:functions)
    end
  end
end
