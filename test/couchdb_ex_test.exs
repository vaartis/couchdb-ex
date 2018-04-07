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
    {:ok, doc} = CouchDBEx.document_insert_one(%{test_value: 1}, "couchdb-ex-test")

    id = doc[:id]

    refute is_nil(id)

    assert match?({:ok, %{"test_value" => 1}}, CouchDBEx.document_get(id, "couchdb-ex-test"))
  end

  test "document_insert_many+document_list" do
    seed = ExUnit.configuration[:seed]

    {:ok, _} =
      Enum.map(seed..seed + 99, &(%{test_value: &1}))
      |> CouchDBEx.document_insert_many("couchdb-ex-test")

    {:ok, %{"rows" => got_docs, "total_rows" => total_count}} =
      CouchDBEx.document_list("couchdb-ex-test", include_docs: true)

    assert total_count == 100

    got_docs
    |> Enum.with_index
    |> Enum.each(fn {e, ind} ->
      assert e["doc"]["test_value"] == seed + ind
    end)
  end

  test "document_delete_one" do
    {:ok, [id: docid, rev: docrev]} = CouchDBEx.document_insert_one(%{test_value: 1}, "couchdb-ex-test")

    assert match?({:ok, _}, CouchDBEx.document_get(docid, "couchdb-ex-test"))

    assert match?({:ok, %{"ok" => true}}, CouchDBEx.document_delete_one(docid, docrev, "couchdb-ex-test"))

    assert match?({:error, _}, CouchDBEx.document_get(docid, "couchdb-ex-test"))
  end

  test "document_delete_many" do
    seed = ExUnit.configuration[:seed]

    {:ok, inserted_docs} =
      Enum.map(seed..seed + 99, &(%{test_value: &1}))
      |> CouchDBEx.document_insert_many("couchdb-ex-test")

    {:ok, deleted_info} =
      inserted_docs
      |> Enum.map(&({&1["id"], &1["rev"]}))
      |> CouchDBEx.document_delete_many("couchdb-ex-test")

    Enum.each(deleted_info, fn e -> assert match?(%{"ok" => true}, e) end)
  end
end
