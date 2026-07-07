defmodule Expert.Provider.Handlers.CodeActionResolve do
  @moduledoc """
  Resolves the `edit` for a deferred code action produced by
  `Expert.Provider.Handlers.CodeAction` when the client supports
  `codeAction/resolve`.

  The action's `data` payload identifies the document (uri and version), the
  original request range, and the refactoring to execute. Edits are computed
  against the current document; if the document has changed since the action
  was listed, the resolve is rejected and the client is expected to request
  code actions again.
  """
  @behaviour Expert.Provider.Handler

  alias Expert.Document.Lookup
  alias Expert.EngineApi
  alias Expert.Project.Store
  alias Forge.Document
  alias Forge.Document.Position
  alias Forge.Document.Range
  alias GenLSP.Requests
  alias GenLSP.Structures

  @impl Expert.Provider.Handler
  def handle(%Requests.CodeActionResolve{params: %Structures.CodeAction{} = action}, _context) do
    with {:ok, data} <- fetch_data(action),
         {:ok, context} <- fetch_context(data["uri"]),
         :ok <- check_version(context.document, data["version"]),
         {:ok, range} <- build_range(context.document, data["range"]),
         {:ok, changes} <-
           resolve_changes(context.project, context.document, range, data["module"]) do
      edit = %Structures.WorkspaceEdit{changes: %{context.document.uri => changes}}
      {:ok, %Structures.CodeAction{action | edit: edit}}
    end
  end

  defp fetch_data(%Structures.CodeAction{data: %{"provider" => "refactor"} = data}) do
    {:ok, data}
  end

  defp fetch_data(_action), do: {:error, :not_resolvable}

  defp fetch_context(uri) when is_binary(uri) do
    {:ok, Lookup.resolve(uri, Store.projects())}
  end

  defp fetch_context(_uri), do: {:error, :invalid_uri}

  defp check_version(%Document{version: version}, version), do: :ok
  defp check_version(_document, _version), do: {:error, :stale_code_action}

  defp resolve_changes(project, document, range, module_name) when is_binary(module_name) do
    case EngineApi.resolve_code_action(project, document, range, module_name) do
      {:ok, changes} -> {:ok, changes}
      _ -> {:error, :refactoring_no_longer_available}
    end
  end

  defp resolve_changes(_project, _document, _range, _module_name),
    do: {:error, :invalid_module}

  defp build_range(%Document{} = document, %{"start" => start_pos, "end" => end_pos}) do
    with {:ok, start_position} <- build_position(document, start_pos),
         {:ok, end_position} <- build_position(document, end_pos) do
      {:ok, Range.new(start_position, end_position)}
    end
  end

  defp build_range(_document, _range), do: {:error, :invalid_range}

  defp build_position(document, %{"line" => line, "character" => character})
       when is_integer(line) and is_integer(character) do
    {:ok, Position.new(document, line, character)}
  end

  defp build_position(_document, _position), do: {:error, :invalid_range}
end
