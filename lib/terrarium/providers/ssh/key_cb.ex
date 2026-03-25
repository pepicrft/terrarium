defmodule Terrarium.Providers.SSH.KeyCb do
  @moduledoc false

  # Custom SSH client key callback that accepts a private key as a PEM string
  # or a file path, passed via key_cb_private.

  @behaviour :ssh_client_key_api

  require Logger

  @impl true
  def is_host_key(_key, _host, _algorithm, _options), do: true

  @impl true
  def add_host_key(_host, _public_key, _options), do: :ok

  @impl true
  def user_key(algorithm, options) do
    key_cb_private = options[:key_cb_private] || []

    cond do
      pem = key_cb_private[:key] ->
        Logger.debug("Decoding SSH key from PEM string", algorithm: algorithm)
        decode_pem(pem)

      path = key_cb_private[:key_path] ->
        expanded = Path.expand(path)
        Logger.debug("Reading SSH key from file", algorithm: algorithm, path: expanded)

        case File.read(expanded) do
          {:ok, pem} ->
            decode_pem(pem)

          {:error, reason} ->
            Logger.error("Failed to read SSH key file", path: expanded, reason: reason)
            {:error, reason}
        end

      true ->
        Logger.error("No SSH key provided in key_cb_private options")
        {:error, :no_key_provided}
    end
  end

  defp decode_pem(pem) do
    case :public_key.pem_decode(pem) do
      [entry | _] ->
        Logger.debug("SSH key decoded from PEM format")
        {:ok, :public_key.pem_entry_decode(entry)}

      [] ->
        # OpenSSH format (ed25519, etc.) — OTP 25+
        case :ssh_file.decode(pem, :openssh_key_v1) do
          [{private_key, _attrs} | _] ->
            Logger.debug("SSH key decoded from OpenSSH format")
            {:ok, private_key}

          _ ->
            Logger.error("Failed to decode SSH key from PEM or OpenSSH format")
            {:error, :pem_decode_failed}
        end
    end
  end
end
