defmodule Terrarium.Telemetry do
  @moduledoc """
  Telemetry events emitted by Terrarium.

  All events follow the `:telemetry.span/3` convention, emitting
  `start`, `stop`, and `exception` events.

  ## Events

  ### `[:terrarium, :create, :start]`

  Emitted when sandbox creation begins.

  - Measurements: `%{system_time: integer}`
  - Metadata: `%{provider: module}`

  ### `[:terrarium, :create, :stop]`

  Emitted when sandbox creation completes.

  - Measurements: `%{duration: integer}`
  - Metadata: `%{provider: module, result: term()}`

  ### `[:terrarium, :destroy, :start | :stop | :exception]`

  - Metadata: `%{sandbox: Terrarium.Sandbox.t()}`

  ### `[:terrarium, :exec, :start | :stop | :exception]`

  - Metadata: `%{sandbox: Terrarium.Sandbox.t(), command: String.t()}`

  ### `[:terrarium, :read_file, :start | :stop | :exception]`

  - Metadata: `%{sandbox: Terrarium.Sandbox.t(), path: String.t()}`

  ### `[:terrarium, :write_file, :start | :stop | :exception]`

  - Metadata: `%{sandbox: Terrarium.Sandbox.t(), path: String.t()}`

  ### `[:terrarium, :transfer, :start | :stop | :exception]`

  - Metadata: `%{sandbox: Terrarium.Sandbox.t(), local_path: String.t(), remote_path: String.t(), file_size: non_neg_integer() | nil}`

  ### `[:terrarium, :ls, :start | :stop | :exception]`

  - Metadata: `%{sandbox: Terrarium.Sandbox.t(), path: String.t()}`

  ### `[:terrarium, :ssh_opts, :start | :stop | :exception]`

  - Metadata: `%{sandbox: Terrarium.Sandbox.t()}`

  ### `[:terrarium, :reconnect, :start | :stop | :exception]`

  - Metadata: `%{sandbox: Terrarium.Sandbox.t()}`

  ## Example

  Attach a handler to log all sandbox operations:

      :telemetry.attach_many(
        "terrarium-logger",
        [
          [:terrarium, :create, :stop],
          [:terrarium, :exec, :stop],
          [:terrarium, :destroy, :stop]
        ],
        fn event, measurements, metadata, _config ->
          Logger.info("\#{inspect(event)} took \#{measurements.duration} native time units")
        end,
        nil
      )
  """

  @doc false
  def span(event, metadata, fun) do
    :telemetry.span([:terrarium, event], metadata, fn ->
      result = fun.()
      {result, %{result: result}}
    end)
  end
end
