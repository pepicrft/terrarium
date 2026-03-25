defmodule Terrarium.ConfigTest do
  use ExUnit.Case, async: true

  alias Terrarium.Sandbox

  @config [
    default: :test,
    providers: [
      test: {Terrarium.TestProvider, from_config: true},
      bare: Terrarium.TestProvider
    ]
  ]

  describe "named providers from config" do
    test "resolves a named provider" do
      assert {:ok, %Sandbox{provider: Terrarium.TestProvider}} =
               Terrarium.create(:bare, config: @config)
    end

    test "resolves a named provider with {module, opts} tuple" do
      assert {:ok, %Sandbox{provider: Terrarium.TestProvider}} =
               Terrarium.create(:test, config: @config)
    end
  end

  describe "default provider from config" do
    test "uses the configured default provider" do
      assert {:ok, %Sandbox{provider: Terrarium.TestProvider}} =
               Terrarium.create(config: @config)
    end

    test "merges config opts with call-site opts" do
      assert {:ok, %Sandbox{provider: Terrarium.TestProvider}} =
               Terrarium.create(config: @config, from_call: true)
    end
  end
end
