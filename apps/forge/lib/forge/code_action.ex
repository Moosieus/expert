defmodule Forge.CodeAction do
  alias Forge.Document.Changes

  defstruct [:title, :kind, :changes, :uri, :data]

  @type code_action_kind :: GenLSP.Enumerations.CodeActionKind.t()

  @type trigger_kind :: GenLSP.Enumerations.CodeActionTriggerKind.t()

  @typedoc """
  JSON-serializable payload round-tripped through the client for `codeAction/resolve`. Actions
  carrying `data` defer their edits until resolved; actions carrying `changes` ship their edits
  inline.
  """
  @type data :: %{optional(String.t()) => term()}

  @type t :: %__MODULE__{
          title: String.t(),
          kind: code_action_kind,
          changes: Changes.t() | nil,
          uri: Forge.uri(),
          data: data() | nil
        }

  @spec new(Forge.uri(), String.t(), code_action_kind(), Changes.t()) :: t()
  def new(uri, title, kind, changes) do
    %__MODULE__{uri: uri, title: title, changes: changes, kind: kind}
  end

  @spec deferred(Forge.uri(), String.t(), code_action_kind(), data()) :: t()
  def deferred(uri, title, kind, data) do
    %__MODULE__{uri: uri, title: title, kind: kind, data: data}
  end
end
