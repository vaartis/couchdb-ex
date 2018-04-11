defmodule CouchDBExTest do
  use ExUnit.Case, async: false
  doctest CouchDBEx

  setup_all do
    children = [
      {CouchDBEx.Worker, [
          hostname: "http://localhost",
          username: "couchdb",
          password: "couchdb",
          auth_method: :cookie
        ]}
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
    test "actually exists" do
      {:ok, res} = CouchDBEx.db_exists?("couchdb-ex-test")

      assert res
    end

    test "doesn't exist" do
      CouchDBEx.db_delete("couchdb-ex-test")

      {:ok, res} = CouchDBEx.db_exists?("couchdb-ex-test")

      refute res
    end
  end

  test "db_info shows has the correct db name" do
    assert match?({:ok, %{"db_name" => "couchdb-ex-test"}}, CouchDBEx.db_info("couchdb-ex-test"))
  end

  test "db_create can create a database" do
    :ok = CouchDBEx.db_create("couchdb-ex-test-2")

    on_exit fn ->
      CouchDBEx.db_delete("couchdb-ex-test-2")
    end

    assert match?({:ok, true}, CouchDBEx.db_exists?("couchdb-ex-test-2"))
  end

  test "db_list has a database in it" do
    {:ok, list} = CouchDBEx.db_list()

    assert "couchdb-ex-test" in list
  end

  test "document_insert_one" do
    {:ok, %{"id" => id}} = CouchDBEx.document_insert_one(%{test_value: 1}, "couchdb-ex-test")

    refute is_nil(id)

    assert match?({:ok, %{"test_value" => 1}}, CouchDBEx.document_get(id, "couchdb-ex-test"))
  end

  test "inserting many documents and retrieving them" do
    seed = ExUnit.configuration[:seed]

    {:ok, _} = seed..seed + 99
      |> Enum.map(&(%{test_value: &1}))
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

  test "deleting a document" do
    {:ok, %{"id" => docid, "rev" => docrev}} = CouchDBEx.document_insert_one(%{test_value: 1}, "couchdb-ex-test")

    assert match?({:ok, _}, CouchDBEx.document_get(docid, "couchdb-ex-test"))

    assert match?({:ok, %{"ok" => true}}, CouchDBEx.document_delete_one(docid, docrev, "couchdb-ex-test"))

    assert match?({:error, _}, CouchDBEx.document_get(docid, "couchdb-ex-test"))
  end

  test "deleting many documents" do
    seed = ExUnit.configuration[:seed]

    {:ok, inserted_docs} = seed..seed + 99
      |> Enum.map(&(%{test_value: &1}))
      |> CouchDBEx.document_insert_many("couchdb-ex-test")

    {:ok, deleted_info} =
      inserted_docs
      |> Enum.map(&({&1["id"], &1["rev"]}))
      |> CouchDBEx.document_delete_many("couchdb-ex-test")

    Enum.each(deleted_info, fn e -> assert match?(%{"ok" => true}, e) end)
  end

  test "upload, get and delete an attachment" do
    {:ok, %{"id" => id, "rev" => rev}} = CouchDBEx.document_insert_one(%{}, "couchdb-ex-test")

    seed = ExUnit.configuration[:seed]

    {:ok, %{"rev" => rev}} =
      CouchDBEx.attachment_upload(
        "couchdb-ex-test",
        id,
        rev,
        "test-attachment-#{seed}",
        "#{seed}",
        content_type: "image/jpeg"
      )

    seed_str = Integer.to_string(seed)
    assert match?(
      {
        :ok,
        ^seed_str,
        "image/jpeg"
      },
      CouchDBEx.attachment_get("couchdb-ex-test", id, rev, "test-attachment-#{seed}")
    )

    {:ok, %{"ok" => true, "rev" => rev}} =
      CouchDBEx.attachment_delete("couchdb-ex-test", id, rev, "test-attachment-#{seed}")

    assert match?(
      {:error, %CouchDBEx.Error{error: "not_found"}},
      CouchDBEx.attachment_get("couchdb-ex-test", id, rev, "test-attachment-#{seed}")
    )
  end

  test "subscribing and unsubscribing works" do

    defmodule ChangesTest do
      use GenServer

      def start_link(opts) do
        GenServer.start_link(__MODULE__, nil, opts)
      end

      def init(_) do
        {:ok, nil}
      end

      def handle_info({:couchdb_change, msg}, _) do
        {:noreply, msg}
      end

      def handle_call(:get, _from, state) do
        {:reply, state, state}
      end

    end

    seed = Integer.to_string(ExUnit.configuration[:seed])

    CouchDBEx.changes_sub("couchdb-ex-test", ChangesTest, ChangesTest)

    CouchDBEx.document_insert_one(%{data: seed}, "couchdb-ex-test")

    # Need to wait a little, it never spawns immidietly
    Process.sleep(100)

    assert Enum.count(Supervisor.which_children(CouchDBEx.Worker.ChangesCommunicator.Supervisor)) == 1

    %{"doc" => %{"data" => ^seed}} = GenServer.call(ChangesTest, :get)

    CouchDBEx.changes_unsub(ChangesTest)

    # Just to be safe
    Process.sleep(100)

    assert Enum.count(Supervisor.which_children(CouchDBEx.Worker.ChangesCommunicator.Supervisor)) == 0
  end
end
