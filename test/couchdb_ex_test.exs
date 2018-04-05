defmodule CouchDBExTest do
  use ExUnit.Case
  doctest CouchDBEx

  setup_all do
    children = [
      {CouchDBEx.Worker, [hostname: "http://couchdb:couchdb@localhost"]}
    ]

    opts = [strategy: :one_for_one, name: CouchDBEx.Test.Supervisor]
    Supervisor.start_link(children, opts)

    :ok
  end

end
