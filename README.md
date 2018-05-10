# CouchDBEx

[![Build Status](https://www.travis-ci.org/vaartis/couchdb-ex.svg?branch=master)](https://www.travis-ci.org/vaartis/couchdb-ex)
[![Coverage Status](https://coveralls.io/repos/github/vaartis/couchdb-ex/badge.svg?branch=master)](https://coveralls.io/github/vaartis/couchdb-ex?branch=master)
[![Hex.pm](https://img.shields.io/hexpm/v/couchdb_ex.svg)](https://hex.pm/packages/couchdb_ex)


This is supposed to be a *good* couchdb interface for elixir,
documented, tested and other things, that's in progress for now, i know
there are erlang and elixir clients already, but they are basically dead and not
documented very good if at all, although you might also want to
look at [icouch](https://hex.pm/packages/icouch)

Some features implemented:

- Single and mass document insertion/deletion/update
- Subscribing to changes in the database
- Basic and cookie authentification
- Database configuration retreival and setting
- Document finding
- Attachment uploading/retreival/deletion
- Index creation/deletion/listing
- Replication

Documentation can be found [here](https://hexdocs.pm/couchdb_ex)

## Usage example

### 1. Add the dependency in your application's `mix.exs`
```elixir
defp deps do
    [
        # ...
        {:couchdb_ex, "~> 0.2.1"},
    ]
end
```

### 2. Use it in your application

#### 2.1. Elixir application
First, add the couchdb worker to your supervisor

```elixir
    children = [
      {CouchDBEx.Worker, [
          hostname: "http://localhost",
          username: "couchdb",
          password: "couchdb",
          auth_method: :cookie # or :basic, if you feel like it
        ]}
    ]

    opts = [strategy: :one_for_one, name: Application.Supervisor]
    Supervisor.start_link(children, opts)
```

#### 2.2. Phoenix framework application
Find the `application.ex` which is usually present in `hello/lib/hello/` where `hello` is your project name. Phoenix uses soft-deprecated `Supervisor.Spec` thus the minor difference in usage.

Then add the couchdb worker to your application module

```elixir
def start(_type, _args) do
    import Supervisor.Spec

    children = [
        supervisor(HelloWeb.Endpoint, []),
        worker(CouchDBEx.Worker, [[
            hostname: "http://localhost",
            username: "couchdb",
            password: "couchdb",
            auth_method: :cookie # or :basic, if you feel like it
        ]])
    ]
    opts = [strategy: :one_for_one, name: Hello.Supervisor]
    Supervisor.start_link(children, opts)
end
```
### 3. You are all set to make DB operations

Now, you can use functions from `CouchDBEx`

```elixir
:ok = CouchDBEx.db_create("couchdb-ex-test")

{:ok, doc} = CouchDBEx.document_insert_one(%{test_value: 1}, "couchdb-ex-test")
```

This library also includes subscribing to database changes with `CouchDBEx.changes_sub` and `_unsub`,
see respective functions documentation for more

## Contribution

Please do open issues and pull requests if you feel like something
is wrong, this library probably doesn't have everything you need yet.
