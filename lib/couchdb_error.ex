defmodule CouchDBEx.Error do
  @enforce_keys [:error, :reason]
  defstruct [:error, :reason]
end
