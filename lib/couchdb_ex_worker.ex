defmodule CouchDBEx.Worker do
  use GenServer

  @moduledoc """
  ## TODO:

  - [ ] `_stats`
  - [ ] `_scheduler`
  - [ ] `_session` - cookie session
  - [ ] `_explain`
  """

  # Client

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  # Server

  @impl true
  def init(args) do
    args = Keyword.merge(
      [
        hostname: "http://localhost",
        port: 5984,
      ],
      args
    )

    children = [
      {__MODULE__.ChangesCommunicator, args}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: CouchDBEx.Worker.Supervisor)

    {:ok, args}
  end

  @impl true
  def handle_call(:couchdb_info, _from, state) do
    with {:ok, resp} <- HTTPoison.get("#{state[:hostname]}:#{state[:port]}"),
         json_resp <- resp.body |> Poison.decode!
      do
      {
        :reply,
        {:ok, json_resp},
        state
      }
      else
        e -> {:reply, {:error, e}, state}
    end
  end


  def handle_call({:db_exists?, db_name}, _from, state) do
    with {:ok, resp} <- HTTPoison.head("#{state[:hostname]}:#{state[:port]}/#{db_name}")
      do {:reply, {:ok, resp.status_code == 200}, state}
      else e -> {:reply, {:error, e}, state}
    end
  end

  def handle_call({:db_info, db_name}, _from, state) do
    with {:ok, resp} <- HTTPoison.get("#{state[:hostname]}:#{state[:port]}/#{db_name}"),
         json_resp <- resp.body |> Poison.decode!
      do {:reply, {:ok, json_resp}, state}
      else e -> {:reply, {:error, e}, state}
    end
  end

  @impl true
  def handle_call({:db_create, db_name, opts}, _from, state) do
    default_opts = [shards: 8]
    final_opts = Keyword.merge(default_opts, opts)

    with {:ok, resp} <- HTTPoison.put(
           "#{state[:hostname]}:#{state[:port]}/#{db_name}",
           "",
           [],
           params: [q: final_opts[:shards]]
         ),
         %{"ok" => true} <- resp.body |> Poison.decode!
      do {:reply, :ok, state}
      else e -> {:reply, {:error, e}, state}
    end
  end

  @impl true
  def handle_call({:db_delete, db_name}, _from, state) do
    with {:ok, resp} <- HTTPoison.delete("#{state[:hostname]}:#{state[:port]}/#{db_name}"),
         %{"ok" => true} <- resp.body |> Poison.decode!
      do {:reply, :ok, state}
      else
        e -> {:reply, {:error, e}, state}
    end
  end

  def handle_call({:db_compact, db_name}, _from, state) do
    with {:ok, resp} <- HTTPoison.post(
           "#{state[:hostname]}:#{state[:port]}/#{db_name}/_compact",
           "",
           [{"Content-Type", "application/json"}]
         ),
         %{"ok" => true} <- resp.body |> Poison.decode!
      do {:reply, :ok, state}
      else
        e -> {:reply, {:error, e}, state}
    end
  end

  def handle_call({:db_list}, _from, state) do
    with {:ok, resp} <- HTTPoison.get("#{state[:hostname]}:#{state[:port]}/_all_dbs"),
         json_resp <- resp.body |> Poison.decode!
      do {:reply, {:ok, json_resp}, state}
      else e -> {:reply, {:error, e}, state}
    end
  end


  @impl true
  def handle_call(:uuid_get, _from, state) do
    case uuid_get_impl(1, state) do
      {:ok, [uuid]} -> {:reply, {:ok, uuid}, state}
      e -> {:reply, e, state}
    end
  end
  @impl true
  def handle_call({:uuid_get, count}, _from, state), do: {:reply, uuid_get_impl(count, state), state}


  @impl true
  def handle_call({:document_insert, database, document_or_documents}, _from, state) do
    # A bulk insert
    if is_list(document_or_documents) do
      documents = document_or_documents

      with {:ok, resp} <- HTTPoison.post(
             "#{state[:hostname]}:#{state[:port]}/#{database}/_bulk_docs",
             Poison.encode!(%{docs: documents}),
             [{"Content-Type", "application/json"}]
           ),
           docs <- resp.body |> Poison.decode!
        do {:reply, {:ok, docs}, state}
        else e -> {:reply, {:error, e}, state}
      end
    else
      document = document_or_documents

      with {:ok, resp} <- HTTPoison.post(
             "#{state[:hostname]}:#{state[:port]}/#{database}",
             Poison.encode!(document),
             [{"Content-Type", "application/json"}]
           ),
           %{"ok" => true, "id" => id, "rev" => rev} <- resp.body |> Poison.decode!
        do {:reply, {:ok, [id: id, rev: rev]}, state}
        else e -> {:reply, {:error, e}, state}
      end
    end
  end

  def handle_call({:document_list, database, opts}, _from, state) do
    maybe_keys = opts[:keys]

    # Pass an empty json object, because CouchDB will error if it sees an empty string here
    maybe_body = unless(is_nil(maybe_keys), do: %{keys: maybe_keys} |> Poison.encode!, else: "{}")

    with {:ok, resp} <- HTTPoison.post(
           "#{state[:hostname]}:#{state[:port]}/#{database}/_all_docs",
           maybe_body,
           [{"Content-Type", "application/json"}],
           params: opts |> Keyword.delete(:keys) |> Enum.into(%{})
         ),
         json_resp <- resp.body |> Poison.decode! do
      if not Map.has_key?(json_resp, "error") do
        {:reply, {:ok, json_resp}, state}
      else
        {:reply, {:error, json_resp}, state}
      end
    else e -> {:reply, e, state}
    end
  end

  @impl true
  def handle_call({:document_get, database, id, opts}, _from, state) do
    with {:ok, resp} <- HTTPoison.get(
           "#{state[:hostname]}:#{state[:port]}/#{database}/#{id}",
           [{"Accept", "application/json"}], # This header is required, because if we request attachments, it'll return JSON as binary data and cause an error
           params: opts
         ),
         json_resp <- resp.body |> Poison.decode! do
      if not Map.has_key?(json_resp, "error") do
        {:reply, {:ok, json_resp}, state}
      else
        {:reply, {:error, json_resp}, state}
      end
    else e -> {:reply, e, state}
    end
  end

  def handle_call({:document_find, database, selector, opts}, _from, state) do
    final_opts = opts |>
      Enum.into(%{}) |> # Transform options into a map
      Map.put(:selector, selector) # Add the selector field

    with {:ok, resp} <- HTTPoison.post(
           "#{state[:hostname]}:#{state[:port]}/#{database}/_find",
           Poison.encode!(final_opts),
           [{"Content-Type", "application/json"}]
         ),
         %{"docs" => _docs} = json_res <- resp.body |> Poison.decode!
    do {:reply, {:ok ,json_res}, state}
    else e-> {:reply, {:error, e}, state}
    end
  end

  @doc """
  Either {id,rev} or [{id,rev}]
  """
  def handle_call({:document_delete, database, id_rev}, from, state) do
    if is_list(id_rev) do
      final_id_rev = Enum.map(id_rev, fn {id,rev} -> %{:_id => id, :_rev => rev, :_deleted => true} end)

      handle_call({:document_insert, database, final_id_rev}, from, state)
    else
      {id, rev} = id_rev
      with {:ok, resp} <- HTTPoison.delete(
             "#{state[:hostname]}:#{state[:port]}/#{database}/#{id}",
             [{"Accept", "application/json"}],
             params: [rev: rev]
           ),
           %{"ok" => _ok} = json_res <- resp.body |> Poison.decode!
        do {:reply, {:ok ,json_res}, state}
        else e-> {:reply, {:error, e}, state}
      end
    end
  end

  @impl true
  def handle_call(
    {:attachment_upload, database, id, {attachment_name, attachment_bindata}, rev, opts}, _from, state
  ) when is_binary(attachment_bindata) do
    with {:ok, resp} <- HTTPoison.put(
           "#{state[:hostname]}:#{state[:port]}/#{database}/#{id}/#{attachment_name}",
           attachment_bindata,
           if(Keyword.has_key?(opts, :content_type), do: [{"Content-Type", opts[:content_type]}], else: []),
           params: [rev: rev]
         ),
         %{"ok" => true, "id" => id, "rev" => rev} <- resp.body |> Poison.decode!
      do {:reply, {:ok, [id: id, rev: rev]}, state}
      else e -> {:reply, e, state}
    end
  end


  @doc """
  ## Notes
  If `index` is a list, it is considered a list of indexing fields, otherwise
  it is used as a full index specification.

  ## Options

  * `ddoc` - name of the design document in which the index will be created.
             By default, each index will be created in its own design document.
             Indexes can be grouped into design documents for efficiency. However, a change to
             one index in a design document will invalidate all other indexes in the
             same document (similar to views)
  * `name` - name of the index. If no name is provided, a name will be generated automatically
  * `type` - can be "json" or "text". Defaults to json
  * `partial_filter_selector` - a selector to apply to documents at indexing time, creating
             a partial index

  """
  def handle_call({:index_create, database, index, opts}, _from, state) do
    final_index = if is_list(index) do
      %{fields: index} # Is index is a list, consider it a list of indexing fields
    else
      index
    end

    final_opts = opts |> Enum.into(%{}) |> Map.put(:index, final_index)

    with {:ok, resp} <- HTTPoison.post(
           "#{state[:hostname]}:#{state[:port]}/#{database}/_index",
           Poison.encode!(final_opts),
           [{"Content-Type", "application/json"}]
         ),
         %{"result" => "created"} = json_res <- resp.body |> Poison.decode!
      do {:reply, {:ok, json_res}, state}
      else e -> {:reply, {:error, e}, state}
    end
  end

  def handle_call({:index_delete, database, ddoc, index_name}, _from, state) do
    with {:ok, resp} <- HTTPoison.delete(
           "#{state[:hostname]}:#{state[:port]}/#{database}/_index/#{ddoc}/json/#{index_name}"
         ),
         %{"ok" => true} <- resp.body |> Poison.decode!
      do {:reply, :ok, state}
      else e -> {:reply, {:error, e}, state}
    end
  end

  def handle_call({:index_list, database}, _from, state) do
    with {:ok, resp} <- HTTPoison.get("#{state[:hostname]}:#{state[:port]}/#{database}/_index"),
         %{"indexes" => indexes, "total_rows" => total} <- resp.body |> Poison.decode!
      do {:reply, {:ok, indexes, total}, state}
      else e -> {:reply, {:error, e}, state}
    end
  end


  @doc """
  ## Options

  * `create_target` - should the target of replication be created or not (defaults to `false`)
  * `continuous` - should the replication be continuous
  * `cancel` - cancel the continuous replication (note that cancel request should be identical to the
                replication request, except the addition of `cancel`)
  """
  def handle_call({:replicate, source, target, opts}, _from, state) do

    final_opts = Keyword.merge(
      [
        source: source,
        target: target
      ],
      opts
    ) |> Enum.into(%{})

    with {:ok, resp} <- HTTPoison.post(
           "#{state[:hostname]}:#{state[:port]}/_replicate",
           Poison.encode!(final_opts),
           [{"Content-Type", "application/json"}]
         ),
         %{"ok" => true} = json_resp <- resp.body |> Poison.decode!
      do {:reply, {:ok, json_resp}, state}
      else e -> {:reply, {:error, e}, state}
    end
  end


  @doc """
  Any option can be nil here, that just skips it. If `section` is nil, key is also `ignored`
  """
  def handle_call({:config_get, node_name, section, key}, _from, state) do
    addr = ("#{state[:hostname]}:#{state[:port]}/"
      <> (if not is_nil(node_name), do: "_node/#{node_name}/", else: "")
      <> "_config/"
      <> (if not is_nil(section), do: "#{section}/", else: "")
      <> (if not is_nil(section) and not is_nil(key), do: "#{key}/", else: ""))

    with {:ok, resp} <- HTTPoison.get(addr),
         json_resp <- resp.body |> Poison.decode!
      do {:reply, {:ok, json_resp}, state}
      else e -> {:reply, {:error, e}, state}
    end
  end

  def handle_call({:config_set, node_name, section, key, value}, _from, state) do
    addr = ("#{state[:hostname]}:#{state[:port]}/"
      <> (if not is_nil(node_name), do: "_node/#{node_name}/", else: "")
      <> "_config/#{section}/#{key}")

    with {:ok, resp} <- HTTPoison.put(addr, Poison.encode!(value)),
         json_resp <- resp.body |> Poison.decode!
      do {:reply, {:ok, json_resp}, state}
      else e -> {:reply, {:error, e}, state}
    end
  end


  @doc """
  Subscribe to changes to the table.

  `watcher_name` is the process name the caller wants the watcher to be known as,
  the watcher may set this name on start (it will be passed as `:name` in the options
  list) so that other processes could communicate with it, otherwise it is used only as a `Supervisor` id.
  This facilitates module reuse, as one might want to use same modules on different
  tables. `modname` is the actual module that will be passed to the supervisor, which
  in turn will start it.

  ## Options

  Options are as described in
  [the official documentation](http://docs.couchdb.org/en/2.1.1/api/database/changes.html),
  except the following defaults:
  * `feed` is `continuous`, this is the only mode supported, trying to change it **WILL RAISE A RuntimeError**
  * `include_docs` is `true`
  * `since` is `now`
  * `heartbeat` is `25`, this is needed to keep the connection alive,
                trying to change it **WILL RAISE a RuntimeError**
  """
  @impl true
  def handle_cast({:changes_sub, database, modname, watcher_name, opts}, state) do
    GenServer.cast(
      CouchDBEx.Worker.ChangesCommunicator,
      {:add_watcher, database, modname, watcher_name, opts}
    )

    {:noreply, state}
  end

  def handle_cast({:changes_unsub, modname}, state) do
    GenServer.cast(CouchDBEx.Worker.ChangesCommunicator, {:remove_watcher, modname})

    {:noreply, state}
  end

  ## Helpers

  defp uuid_get_impl(count, state) do
    with {:ok, resp} <- HTTPoison.get("#{state[:hostname]}:#{state[:port]}/_uuids", [], params: [count: count]),
         %{"uuids" => uuids} <- resp.body |> Poison.decode!
      do {:ok, uuids}
      else e -> {:error, e}
    end
  end

end
