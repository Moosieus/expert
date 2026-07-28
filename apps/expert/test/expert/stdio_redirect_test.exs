defmodule Expert.StdioRedirectTest do
  use ExUnit.Case, async: false

  @protocol "PROTOCOL_SENTINEL_ON_STDOUT"

  # The redirect is installed by the emulator at boot, so it can only be exercised by
  # booting a child VM with `-user` and reading its real file descriptors. Each script
  # is run twice: once capturing stdout alone, once with stderr merged in. A sentinel
  # absent from the first and present in the second was written to stderr.
  describe "-user Expert.StdioRedirect" do
    test "the protocol device owns stdout and every rogue write goes to stderr" do
      rogue = ~w(
        ROGUE_io_puts
        ROGUE_io_write
        ROGUE_io_inspect
        ROGUE_io_puts_user
        ROGUE_io_puts_stdio
        ROGUE_io_puts_standard_io
        ROGUE_erlang_io_format
        ROGUE_dbg
        ROGUE_spawned_process
        ROGUE_task
        ROGUE_logger
      )

      script = """
      IO.puts("ROGUE_io_puts")
      IO.write("ROGUE_io_write\\n")
      IO.inspect(:ROGUE_io_inspect)
      IO.puts(:user, "ROGUE_io_puts_user")
      IO.puts(:stdio, "ROGUE_io_puts_stdio")
      IO.puts(:standard_io, "ROGUE_io_puts_standard_io")
      :io.format("~s~n", ["ROGUE_erlang_io_format"])

      value = "ROGUE_dbg"
      dbg(value)

      spawn(fn -> IO.puts("ROGUE_spawned_process") end)
      Task.async(fn -> IO.puts("ROGUE_task") end) |> Task.await()

      require Logger
      Logger.error("ROGUE_logger")
      Process.sleep(100)

      IO.binwrite(Expert.StdioRedirect.protocol_device(), "#{@protocol}")
      """

      stdout = run(script)
      merged = run(script, stderr_to_stdout: true)

      assert stdout =~ @protocol, "protocol output missing from stdout"

      for sentinel <- rogue do
        refute stdout =~ sentinel, "#{sentinel} leaked onto the protocol channel (stdout)"
        assert merged =~ sentinel, "#{sentinel} did not reach stderr"
      end
    end

    test "stray IO on a remote node (over distribution) stays off stdout" do
      # Remotely spawned workers inherit the *caller's* group leader, which is what put
      # project compilation output onto the protocol channel to begin with.
      stdout =
        run("""
        cookie = :expert_stdio_redirect_cookie
        peer = :"peer\#{System.pid()}@127.0.0.1"

        connected? =
          with {:ok, _} <- Node.start(:"mgr\#{System.pid()}@127.0.0.1", :longnames) do
            Node.set_cookie(cookie)

            Port.open({:spawn_executable, System.find_executable("elixir")}, [
              :binary, :exit_status, line: 65536,
              args: ["--name", Atom.to_string(peer), "--cookie", Atom.to_string(cookie),
                     "--no-halt", "-e", "Process.sleep(:infinity)"]
            ])

            Enum.reduce_while(1..60, false, fn _, _ ->
              if Node.connect(peer) == true do
                {:halt, true}
              else
                Process.sleep(200)
                {:cont, false}
              end
            end)
          else
            _ -> false
          end

        if connected? do
          :erpc.call(peer, IO, :puts, ["REMOTE_STRAY_SENTINEL"])
          :erpc.cast(peer, System, :halt, [0])
          Process.sleep(300)
          IO.binwrite(Expert.StdioRedirect.protocol_device(), "#{@protocol}")
        else
          IO.binwrite(Expert.StdioRedirect.protocol_device(), "SETUP_UNAVAILABLE")
        end
        """)

      if stdout =~ "SETUP_UNAVAILABLE" do
        # No distribution available (sandboxed CI, epmd trouble). The redirect itself is
        # covered by the local test, so don't fail the build over it.
        IO.puts(:stderr, "[stdio_redirect] distributed case skipped: no peer node available")
      else
        assert stdout =~ @protocol

        refute stdout =~ "REMOTE_STRAY_SENTINEL",
               "remote-node stray IO leaked onto the protocol channel (this is the original bug)"
      end
    end

    test "protocol_device/0 is nil when booted without the flag" do
      assert run("IO.puts(:stderr, inspect(Expert.StdioRedirect.protocol_device()))",
               user_flag: false,
               stderr_to_stdout: true
             ) =~ "nil"
    end
  end

  defp run(script, opts \\ []) do
    stderr_to_stdout? = Keyword.get(opts, :stderr_to_stdout, false)
    user_flag? = Keyword.get(opts, :user_flag, true)

    suffix = "#{System.pid()}_#{:erlang.unique_integer([:positive])}"
    path = Path.join(System.tmp_dir!(), "stdio_redirect_#{suffix}.exs")
    File.write!(path, script)
    on_exit(fn -> File.rm(path) end)

    ebins =
      [Mix.Project.build_path(), "lib", "*", "ebin"]
      |> Path.join()
      |> Path.wildcard()

    erl_flags =
      Enum.map_join(ebins, " ", &"-pa #{&1}") <>
        if user_flag?, do: " -user Elixir.Expert.StdioRedirect", else: ""

    args = ["--erl", erl_flags, path]
    elixir = System.find_executable("elixir")

    {output, _status} =
      case :os.type() do
        {:win32, _} ->
          System.cmd("cmd", ["/c", elixir | args], stderr_to_stdout: stderr_to_stdout?)

        _ ->
          System.cmd(elixir, args, stderr_to_stdout: stderr_to_stdout?)
      end

    output
  end
end
