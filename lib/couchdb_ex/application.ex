defmodule CouchDBEx.Application do
  @moduledoc false

  use Application

  def start(_type, _args) do
    children = [
      CouchDBEx.Worker
    ]

    opts = [strategy: :one_for_one, name: CouchDBEx.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
