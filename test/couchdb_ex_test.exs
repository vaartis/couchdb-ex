defmodule CouchDBExTest do
  use ExUnit.Case, async: false
  doctest CouchDBEx

  setup_all do
    children = [
      {CouchDBEx.Worker, [hostname: "http://couchdb:couchdb@localhost"]}
    ]

    opts = [strategy: :one_for_one, name: CouchDBEx.Test.Supervisor]
    Supervisor.start_link(children, opts)

    :ok
  end

  setup do
    :ok = CouchDBEx.db_create("couchdb-ex-test")

    on_exit fn ->
      CouchDBEx.db_delete("couchdb-ex-test")
    end
  end

  test "CouchDB info" do
    {:ok, i} = CouchDBEx.couchdb_info()

    assert i["couchdb"] == "Welcome"
  end

  describe "db_exists?" do
    test "exists" do
      {:ok, res} = CouchDBEx.db_exists?("couchdb-ex-test")

      assert res
    end

    test "doesn't exist" do
      CouchDBEx.db_delete("couchdb-ex-test")

      {:ok, res} = CouchDBEx.db_exists?("couchdb-ex-test")

      refute res
    end
  end

  test "db_info" do
    assert match?({:ok, %{"db_name" => "couchdb-ex-test"}}, CouchDBEx.db_info("couchdb-ex-test"))
  end

  test "db_create" do
    :ok = CouchDBEx.db_create("couchdb-ex-test-2")

    on_exit fn ->
      CouchDBEx.db_delete("couchdb-ex-test-2")
    end

    assert match?({:ok, true}, CouchDBEx.db_exists?("couchdb-ex-test-2"))
  end

  test "db_list" do
    {:ok, list} = CouchDBEx.db_list()

    assert "couchdb-ex-test" in list
  end

  test "document_insert_one" do
    {:ok, doc} = CouchDBEx.document_insert_one("couchdb-ex-test", %{test_value: 1})

    id = doc[:id]

    refute is_nil(id)

    assert match?({:ok, %{"test_value" => 1}}, CouchDBEx.document_get("couchdb-ex-test", id))
  end

  test "document_insert_many" do
    {:ok, [doc1, doc2]} = CouchDBEx.document_insert_many("couchdb-ex-test", [%{test_value: 1}, %{test_value: 2}])

    {id1, id2} = {doc1["id"], doc2["id"]}

    refute is_nil(id1) && is_nil(id2)
  end

end
