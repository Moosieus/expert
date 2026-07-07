defmodule Expert.Provider.Handlers.CodeActionResolveTest do
  use ExUnit.Case, async: false

  alias Expert.Provider.Handlers
  alias Forge.Document
  alias GenLSP.Requests.CodeActionResolve
  alias GenLSP.Structures

  setup do
    start_supervised!({Document.Store, derive: [analysis: &Forge.Ast.analyze/1]})
    start_supervised!({Expert.Project.Store, []})
    Expert.Project.Store.set_projects([])
    :ok
  end

  defp resolve_request(action) do
    %CodeActionResolve{id: 1, params: action}
  end

  defp deferred_action(uri, data_overrides) do
    data =
      Map.merge(
        %{
          "provider" => "refactor",
          "module" => "Elixir.Forge.Refactor.Pipeline.IntroducePipe",
          "uri" => uri,
          "version" => 1,
          "range" => %{
            "start" => %{"line" => 1, "character" => 1},
            "end" => %{"line" => 1, "character" => 1}
          }
        },
        data_overrides
      )

    %Structures.CodeAction{title: "Introduce pipe", kind: "refactor.rewrite", data: data}
  end

  test "rejects actions without a resolvable data payload" do
    action = %Structures.CodeAction{title: "Some action", data: nil}

    assert {:error, :not_resolvable} =
             Handlers.CodeActionResolve.handle(resolve_request(action), nil)
  end

  test "rejects payloads without a document uri" do
    action = deferred_action(nil, %{"uri" => nil})

    assert {:error, :invalid_uri} =
             Handlers.CodeActionResolve.handle(resolve_request(action), nil)
  end

  test "rejects resolve when the document version has moved on" do
    uri = "file:///stale_resolve_test.ex"
    :ok = Document.Store.open(uri, "x |> foo()\n", 3, "elixir")

    action = deferred_action(uri, %{"version" => 2})

    assert {:error, :stale_code_action} =
             Handlers.CodeActionResolve.handle(resolve_request(action), nil)
  end

  test "rejects payloads with a malformed range" do
    uri = "file:///bad_range_resolve_test.ex"
    :ok = Document.Store.open(uri, "x |> foo()\n", 1, "elixir")

    action = deferred_action(uri, %{"range" => %{"start" => "wat"}})

    assert {:error, :invalid_range} =
             Handlers.CodeActionResolve.handle(resolve_request(action), nil)
  end
end
