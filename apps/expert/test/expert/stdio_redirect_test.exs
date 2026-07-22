defmodule Expert.StdioRedirectTest do
  use ExUnit.Case, async: false

  @protocol "PROTOCOL_SENTINEL_ON_STDOUT"

  describe "install/0" do
    test "protocol writes reach the device; every rogue write reaches stderr" do
      # Each entry writes its sentinel through a different rogue path. After isolation, none may
      # reach the protocol device (stdout); all must reach stderr.
      sentinels = ~w(
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
      )

      {stdout, stderr} =
        run_in_child("""
        IO.puts("ROGUE_io_puts")
        IO.write("ROGUE_io_write\\n")
        IO.inspect(:ROGUE_io_inspect)
        IO.puts(:user, "ROGUE_io_puts_user")
        IO.puts(:stdio, "ROGUE_io_puts_stdio")
        IO.puts(:standard_io, "ROGUE_io_puts_standard_io")
        :io.format("~s~n", ["ROGUE_erlang_io_format"])

        value = "ROGUE_dbg"
        dbg(value)

        parent = self()
        spawn(fn -> IO.puts("ROGUE_spawned_process"); send(parent, :spawned_done) end)
        receive do :spawned_done -> :ok after 2000 -> :ok end

        Task.async(fn -> IO.puts("ROGUE_task") end) |> Task.await()

        # install/0 is idempotent, and the protocol channel still works.
        {:ok, ^device} = Expert.StdioRedirect.install()
        IO.binwrite(device, "#{@protocol}")
        """)

      assert stdout =~ @protocol, "protocol output missing from stdout"
      refute stderr =~ @protocol, "protocol output leaked onto stderr"

      for sentinel <- sentinels do
        refute stdout =~ sentinel, "#{sentinel} leaked onto the protocol channel (stdout)"
        assert stderr =~ sentinel, "#{sentinel} did not reach stderr"
      end
    end

    test "stray IO on a remote node (over distribution) lands on this node's stderr" do
      {stdout, stderr} =
        run_in_child("""
        # Globally-unique names: :erlang.unique_integer resets per VM, so a
        # parallel matrix sharing a host/epmd would otherwise collide on `mgr1@`.
        suffix = "\#{System.pid()}_\#{:erlang.unique_integer([:positive])}"
        peer = :"peer\#{suffix}@127.0.0.1"

        result =
          try do
            if match?({:ok, _}, Node.start(:"mgr\#{suffix}@127.0.0.1", :longnames)) do
              Node.set_cookie(:expert_isolation_test_cookie)

              Port.open({:spawn_executable, System.find_executable("elixir")}, [
                :binary, :exit_status, :stderr_to_stdout, line: 65536,
                args: ["--name", Atom.to_string(peer), "--cookie", "expert_isolation_test_cookie",
                       "--no-halt", "-e", "Process.sleep(:infinity)"]
              ])

              connected? =
                Enum.reduce_while(1..80, false, fn _, _ ->
                  if Node.connect(peer) == true and peer in Node.list() do
                    {:halt, true}
                  else
                    Process.sleep(200)
                    {:cont, false}
                  end
                end)

              if connected? do
                # Runs on the peer; the worker inherits our (redirected) group leader.
                :erpc.call(peer, IO, :puts, ["REMOTE_STRAY_SENTINEL"])
                :erpc.cast(peer, System, :halt, [0])
                :ok
              else
                :setup_failed
              end
            else
              :setup_failed
            end
          rescue
            _ -> :setup_failed
          end

        case result do
          :ok -> IO.binwrite(device, "#{@protocol}")
          :setup_failed -> IO.binwrite(device, "SETUP_UNAVAILABLE")
        end
        """)

      if stdout =~ "SETUP_UNAVAILABLE" do
        # No peer node here (Windows, or epmd/distribution flakiness); the redirect itself is
        # covered by the local test, so don't fail on it.
        IO.puts(:stderr, "[stdio_redirect] distributed case skipped: no peer node available")
      else
        assert stdout =~ @protocol

        refute stdout =~ "REMOTE_STRAY_SENTINEL",
               "remote-node stray IO leaked onto the protocol channel (this is the original bug)"

        assert stderr =~ "REMOTE_STRAY_SENTINEL",
               "remote-node stray IO did not reach the manager's stderr"
      end
    end
  end

  defp run_in_child(body) do
    tmp = System.tmp_dir!()
    # Qualify with the OS pid so parallel matrix jobs sharing /tmp don't collide.
    suffix = "#{System.pid()}_#{:erlang.unique_integer([:positive])}"
    script_path = Path.join(tmp, "stdio_redirect_script_#{suffix}.exs")
    result_path = Path.join(tmp, "stdio_redirect_result_#{suffix}.bin")

    script = """
    {:ok, stdout_io} = StringIO.open("")
    {:ok, stderr_io} = StringIO.open("")
    Process.unregister(:user)
    Process.register(stdout_io, :user)
    Process.unregister(:standard_error)
    Process.register(stderr_io, :standard_error)

    {:ok, device} = Expert.StdioRedirect.install()

    result =
      try do
        #{body}

        {_, out} = StringIO.contents(stdout_io)
        {_, err} = StringIO.contents(stderr_io)
        {:captured, out, err}
      rescue
        e -> {:child_error, Exception.format(:error, e, __STACKTRACE__)}
      end

    File.write!(#{inspect(result_path)}, :erlang.term_to_binary(result))
    """

    File.write!(script_path, script)
    on_exit(fn -> File.rm(script_path) end)
    on_exit(fn -> File.rm(result_path) end)

    {output, status} = run_elixir(script_path)

    if not File.exists?(result_path) do
      flunk("child produced no result file (exit #{status})\n--- child output ---\n#{output}")
    end

    result_path
    |> File.read!()
    |> :erlang.binary_to_term()
    |> case do
      {:captured, out, err} -> {out, err}
      {:child_error, message} -> flunk("child raised:\n#{message}")
    end
  end

  defp run_elixir(script_path) do
    elixir = System.find_executable("elixir")

    pa =
      [Mix.Project.build_path(), "lib", "*", "ebin"]
      |> Path.join()
      |> Path.wildcard()
      |> Enum.flat_map(&["-pa", &1])

    args = pa ++ [script_path]

    case :os.type() do
      {:win32, _} -> System.cmd("cmd", ["/c", elixir | args], stderr_to_stdout: true)
      _ -> System.cmd(elixir, args, stderr_to_stdout: true)
    end
  end
end
