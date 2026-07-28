defmodule Expert.StdioRedirect do
  @moduledoc """
  Reserves `:stdio` for the LSP protocol, sending everything else to `:standard_error`.

  Installed with the (undocumented) `-user` emulator flag, which makes OTP call
  `start/0` in place of starting `user_drv` itself. We start `user_drv` anyway, so it
  still owns fd 0/1 and does all of the tty work, and keep its I/O server as the
  protocol device. A device forwarding to `:standard_error` is registered as `:user`
  in its stead.

  This runs inside `kernel_sup`, before `application_controller` and any application,
  so nothing has captured a group leader yet. Later processes resolve `:user` by name
  and find the forwarder, which means no group leaders have to be moved.
  """

  @protocol_device {__MODULE__, :protocol_device}
  @reads [:get_chars, :get_line, :get_until, :get_password]

  @doc """
  The device owning `:stdio`, or `nil` when booted without `-user`.
  """
  @spec protocol_device() :: pid() | nil
  def protocol_device, do: :persistent_term.get(@protocol_device, nil)

  @doc """
  Entry point for the `-user` boot flag, invoked by `user_sup` rather than directly.
  """
  @spec start() :: pid()
  def start do
    _ = :user_drv.start(%{initial_shell: :noshell, input: :cooked})

    if device = await_user(100) do
      :persistent_term.put(@protocol_device, device)
      Process.unregister(:user)
    end

    redirect = spawn(&loop/0)
    Process.register(redirect, :user)
    redirect
  end

  # `user_drv` registers its I/O server as `:user` asynchronously.
  defp await_user(0), do: nil

  defp await_user(attempts) do
    case Process.whereis(:user) do
      device when is_pid(device) ->
        device

      nil ->
        Process.sleep(10)
        await_user(attempts - 1)
    end
  end

  defp loop do
    receive do
      # `:standard_error` only understands a handful of options, and would answer
      # `{:error, :enotsup}` to the `[binary: true]` Elixir itself sets on boot.
      {:io_request, from, reply_as, {:setopts, _opts}} ->
        reply(from, reply_as, :ok)

      {:io_request, from, reply_as, :getopts} ->
        reply(from, reply_as, binary: true, encoding: :latin1)

      {:io_request, from, reply_as, request} when elem(request, 0) in @reads ->
        reply(from, reply_as, :eof)

      # `:standard_error` answers the original caller itself, which is legal because
      # clients match replies on the reference alone.
      {:io_request, _from, _reply_as, _request} = request ->
        send(:standard_error, request)
        loop()

      _ignored ->
        loop()
    end
  end

  defp reply(from, reply_as, reply) do
    send(from, {:io_reply, reply_as, reply})
    loop()
  end
end
