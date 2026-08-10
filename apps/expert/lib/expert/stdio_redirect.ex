defmodule Expert.StdioRedirect do
  @moduledoc """
  An IO server used to redirect all would-be `:stdio` writes to `:stderr`, allowing GenLSP exclusive access to `:stdio`.
  """

  @protocol_device {__MODULE__, :protocol_device}

  @doc """
  Swaps the boot-time `:user` process (the normal I/O device for `:stdio`) with one that writes
  output to `:standard_error` instead, and returns the PID for the original `:user`.
  """
  @spec install() :: {:ok, pid()} | {:error, term()}
  def install do
    case protocol_device() do
      device when is_pid(device) -> {:ok, device}
      nil -> do_install()
    end
  end

  defp do_install do
    case Process.whereis(:user) do
      protocol_device when is_pid(protocol_device) ->
        redirect = start()

        :io.setopts(protocol_device, binary: true, encoding: :latin1)

        swap_user(redirect)
        redirect_group_leaders(redirect)

        :persistent_term.put(@protocol_device, protocol_device)
        {:ok, protocol_device}

      _ ->
        {:error, :no_user_device}
    end
  end

  defp swap_user(redirect) do
    case Process.whereis(:user) do
      nil -> :ok
      _pid -> Process.unregister(:user)
    end

    Process.register(redirect, :user)
  end

  defp redirect_group_leaders(redirect) do
    :erlang.group_leader(redirect, self())

    case Process.whereis(:application_controller) do
      pid when is_pid(pid) -> :erlang.group_leader(redirect, pid)
      _ -> :ok
    end
  end

  defp protocol_device, do: :persistent_term.get(@protocol_device, nil)

  defp start, do: spawn(fn -> loop() end)

  defp loop do
    receive do
      {:io_request, _from, _reply_as, _request} = request ->
        send(:standard_error, request)
        loop()

      _ignored ->
        loop()
    end
  end
end
