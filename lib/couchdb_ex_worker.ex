defmodule CouchDBEx.Worker do
  use GenServer

  alias CouchDBEx.HTTPClient

  @moduledoc false


  ## TODO:
  #
  # - [ ] `_stats`
  # - [ ] `_scheduler`
  # - [ ] `_explain`


  # Client

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  # Server

  @impl true
  def init(args) do
    # Some default options..
    args = Keyword.merge(
      [
        hostname: "http://localhost",
        port: 5984,
      ],
      args
    )

    children = [
      {__MODULE__.AuthServer, args}
    ]

    # Other modules have no buisness with auth data, better remove it
    args = args
    |> Keyword.delete(:auth_method)
    |> Keyword.delete(:username)
    |> Keyword.delete(:password)
    |> Keyword.delete(:cookie_session_minutes)

    # Add the changes communicator server now, it will not have any auth data,
    # just like the main worker
    children = [{__MODULE__.ChangesCommunicator, args} | children]

    Supervisor.start_link(children, strategy: :one_for_one, name: CouchDBEx.Worker.Supervisor)

    {:ok, args}
  end

  @impl true
  def handle_call(:couchdb_info, _from, state) do
    with {:ok, resp} <- HTTPClient.get("#{state[:hostname]}:#{state[:port]}"),
         json_resp <- resp.body |> Poison.decode!
      do
      {
        :reply,
        {:ok, json_resp},
        state
      }
      else
        e -> {:reply, transform_error(e), state}
    end
  end


  def handle_call({:db_exists?, db_name}, _from, state) do
    with {:ok, resp} <- HTTPClient.head("#{state[:hostname]}:#{state[:port]}/#{db_name}")
      do {:reply, {:ok, resp.status_code == 200}, state}
      else e -> {:reply, transform_error(e), state}
    end
  end

  def handle_call({:db_info, db_name}, _from, state) do
    with {:ok, resp} <- HTTPClient.get("#{state[:hostname]}:#{state[:port]}/#{db_name}"),
         json_resp <- resp.body |> Poison.decode!
      do {:reply, {:ok, json_resp}, state}
      else e -> {:reply, transform_error(e), state}
    end
  end

  @impl true
  def handle_call({:db_create, db_name, opts}, _from, state) do
    default_opts = [shards: 8]
    final_opts = Keyword.merge(default_opts, opts)

    with {:ok, resp} <- HTTPClient.put(
           "#{state[:hostname]}:#{state[:port]}/#{db_name}",
           "",
           [],
           params: [q: final_opts[:shards]]
         ),
         %{"ok" => true} <- resp.body |> Poison.decode!
      do {:reply, :ok, state}
      else e -> {:reply, transform_error(e), state}
    end
  end

  @impl true
  def handle_call({:db_delete, db_name}, _from, state) do
    with {:ok, resp} <- HTTPClient.delete("#{state[:hostname]}:#{state[:port]}/#{db_name}"),
         %{"ok" => true} <- resp.body |> Poison.decode!
      do {:reply, :ok, state}
      else
        e -> {:reply, transform_error(e), state}
    end
  end

  def handle_call({:db_compact, db_name}, _from, state) do
    with {:ok, resp} <- HTTPClient.post(
           "#{state[:hostname]}:#{state[:port]}/#{db_name}/_compact",
           "",
           [{"Content-Type", "application/json"}]
         ),
         %{"ok" => true} <- resp.body |> Poison.decode!
      do {:reply, :ok, state}
      else
        e -> {:reply, transform_error(e), state}
    end
  end

  def handle_call({:db_list}, _from, state) do
    with {:ok, resp} <- HTTPClient.get("#{state[:hostname]}:#{state[:port]}/_all_dbs"),
         json_resp <- resp.body |> Poison.decode!
      do {:reply, {:ok, json_resp}, state}
      else e -> {:reply, transform_error(e), state}
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
  def handle_call(
    {:document_insert, document_or_documents, database}, _from, state
  ) when is_map(document_or_documents) or is_list(document_or_documents) do
    # A bulk insert
    if is_list(document_or_documents) do
      documents = document_or_documents

      with {:ok, resp} <- HTTPClient.post(
             "#{state[:hostname]}:#{state[:port]}/#{database}/_bulk_docs",
             Poison.encode!(%{docs: documents}),
             [{"Content-Type", "application/json"}]
           ),
           docs <- resp.body |> Poison.decode!
        do {:reply, {:ok, docs}, state}
        else e -> {:reply, transform_error(e), state}
      end
    else
      document = document_or_documents

      with {:ok, resp} <- HTTPClient.post(
             "#{state[:hostname]}:#{state[:port]}/#{database}",
             Poison.encode!(document),
             [{"Content-Type", "application/json"}]
           ),
           %{"ok" => true} = rp <- resp.body |> Poison.decode!
        do {:reply, {:ok, rp}, state}
        else e -> {:reply, transform_error(e), state}
      end
    end
  end

  def handle_call({:document_list, database, opts}, _from, state) do
    maybe_keys = opts[:keys]

    # Pass an empty json object, because CouchDB will error if it sees an empty string here
    maybe_body = if(is_nil(maybe_keys), do: "{}", else: %{keys: maybe_keys} |> Poison.encode!)

    with {:ok, resp} <- HTTPClient.post(
           "#{state[:hostname]}:#{state[:port]}/#{database}/_all_docs",
           maybe_body,
           [{"Content-Type", "application/json"}],
           params: opts |> Keyword.delete(:keys) |> Enum.into(%{})
         ),
         json_resp <- resp.body |> Poison.decode! do
      if not Map.has_key?(json_resp, "error") do
        {:reply, {:ok, json_resp}, state}
      else
        {:reply, transform_error(json_resp), state}
      end
    else e -> {:reply, e, state}
    end
  end

  @impl true
  def handle_call({:document_get, id, database, opts}, _from, state) do
    with {:ok, resp} <- HTTPClient.get(
           "#{state[:hostname]}:#{state[:port]}/#{database}/#{id}",
           [{"Accept", "application/json"}], # This header is required, because if we request attachments, it'll return JSON as binary data and cause an error
           params: opts
         ),
         json_resp <- resp.body |> Poison.decode! do
      if not Map.has_key?(json_resp, "error") do
        {:reply, {:ok, json_resp}, state}
      else
        {:reply, transform_error(json_resp), state}
      end
    else e -> {:reply, e, state}
    end
  end

  def handle_call({:document_find, selector, database, opts}, _from, state) when is_map(selector) do
    final_opts = opts |>
      Enum.into(%{}) |> # Transform options into a map
      Map.put(:selector, selector) # Add the selector field

    with {:ok, resp} <- HTTPClient.post(
           "#{state[:hostname]}:#{state[:port]}/#{database}/_find",
           Poison.encode!(final_opts),
           [{"Content-Type", "application/json"}]
         ),
         %{"docs" => _docs} = json_res <- resp.body |> Poison.decode!
    do {:reply, {:ok, json_res}, state}
    else e -> {:reply, transform_error(e), state}
    end
  end

  @doc """
  Either {id,rev} or [{id,rev}]
  """
  def handle_call(
    {:document_delete, id_rev, database}, from, state
  ) when is_tuple(id_rev) or is_list(id_rev) do
    if is_list(id_rev) do
      final_id_rev = Enum.map(id_rev, fn {id, rev} -> %{:_id => id, :_rev => rev, :_deleted => true} end)

      handle_call({:document_insert, final_id_rev, database}, from, state)
    else
      {id, rev} = id_rev
      with {:ok, resp} <- HTTPClient.delete(
             "#{state[:hostname]}:#{state[:port]}/#{database}/#{id}",
             [{"Accept", "application/json"}],
             params: [rev: rev]
           ),
           %{"ok" => _ok} = json_res <- resp.body |> Poison.decode!
        do {:reply, {:ok, json_res}, state}
        else e -> {:reply, transform_error(e), state}
      end
    end
  end


  @impl true
  def handle_call(
    {:attachment_upload, database, id, rev, {attachment_name, attachment_bindata}, opts}, _from, state
  ) when is_binary(attachment_bindata) do
    with {:ok, resp} <- HTTPClient.put(
           "#{state[:hostname]}:#{state[:port]}/#{database}/#{id}/#{attachment_name}",
           attachment_bindata,
           if(Keyword.has_key?(opts, :content_type), do: [{"Content-Type", opts[:content_type]}], else: []),
           params: [rev: rev]
         ),
         %{"ok" => true} = rp <- resp.body |> Poison.decode!
      do {:reply, {:ok, rp}, state}
      else e -> {:reply, e, state}
    end
  end

  @impl true
  def handle_call({:attachment_get, database, docid, rev, name}, _from, state) do
    with {:ok, resp} <- HTTPClient.get(
           "#{state[:hostname]}:#{state[:port]}/#{database}/#{docid}/#{name}",
           [],
           params: [rev: rev]
         ),
         %HTTPoison.Response{status_code: 200} <- resp do
      {_, content_type} = Enum.find(resp.headers, fn {h, _} -> h == "Content-Type" end)
      {:reply, {:ok, resp.body,content_type}, state}
    else
      %HTTPoison.Response{body: einfo} ->
        {:reply, transform_error(einfo |> Poison.decode!), state}
      e ->
        {:reply, transform_error(e)}
    end
  end

  @impl true
  def handle_call(
    {:attachment_delete, database, id, rev, attachment_name}, _from, state
  ) do
    with {:ok, resp} <- HTTPClient.delete(
           "#{state[:hostname]}:#{state[:port]}/#{database}/#{id}/#{attachment_name}",
           [],
           params: [rev: rev]
         ),
         json_resp <- resp.body |> Poison.decode!,
         %{"ok" => true} = rp <- json_resp
      do {:reply, {:ok, rp}, state}
      else e -> {:reply, e, state}
    end
  end

  @impl true
  def handle_call(
    {:index_create, index, database, opts}, _from, state
  ) when is_map(index) or is_list(index) do
    final_index = if is_list(index) do
      %{fields: index} # Is index is a list, consider it a list of indexing fields
    else
      index
    end

    final_opts = opts |> Enum.into(%{}) |> Map.put(:index, final_index)

    with {:ok, resp} <- HTTPClient.post(
           "#{state[:hostname]}:#{state[:port]}/#{database}/_index",
           Poison.encode!(final_opts),
           [{"Content-Type", "application/json"}]
         ),
         %{"result" => "created"} = json_res <- resp.body |> Poison.decode!
      do {:reply, {:ok, json_res}, state}
      else e -> {:reply, transform_error(e), state}
    end
  end

  @impl true
  def handle_call({:index_delete, database, ddoc, index_name}, _from, state) do
    with {:ok, resp} <- HTTPClient.delete(
           "#{state[:hostname]}:#{state[:port]}/#{database}/_index/#{ddoc}/json/#{index_name}"
         ),
         %{"ok" => true} <- resp.body |> Poison.decode!
      do {:reply, :ok, state}
      else e -> {:reply, transform_error(e), state}
    end
  end

  @impl true
  def handle_call({:index_list, database}, _from, state) do
    with {:ok, resp} <- HTTPClient.get("#{state[:hostname]}:#{state[:port]}/#{database}/_index"),
         %{"indexes" => indexes, "total_rows" => total} <- resp.body |> Poison.decode!
      do {:reply, {:ok, indexes, total}, state}
      else e -> {:reply, transform_error(e), state}
    end
  end

  @impl true
  def handle_call({:view_exec, ddoc, view, db, opts}, _from, state) do
    with {:ok, resp} <- HTTPClient.post(
           "#{state[:hostname]}:#{state[:port]}/#{db}/_design/#{ddoc}/_view/#{view}",
           "",
           [{"Content-Type", "application/json"}],
           params: opts
         ),
    %{"total_rows" => _} = json_resp <- resp.body |> Poison.decode!
      do {:reply, {:ok, json_resp}, state}
      else e -> {:reply, transform_error(e), state}
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

    with {:ok, resp} <- HTTPClient.post(
           "#{state[:hostname]}:#{state[:port]}/_replicate",
           Poison.encode!(final_opts),
           [{"Content-Type", "application/json"}],
           recv_timeout: :infinity
         ),
         %{"ok" => true} = json_resp <- resp.body |> Poison.decode!
      do {:reply, {:ok, json_resp}, state}
      else e -> {:reply, transform_error(e), state}
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

    with {:ok, resp} <- HTTPClient.get(addr),
         json_resp <- resp.body |> Poison.decode!
      do {:reply, {:ok, json_resp}, state}
      else e -> {:reply, transform_error(e), state}
    end
  end

  def handle_call({:config_set, node_name, section, key, value}, _from, state) do
    addr = ("#{state[:hostname]}:#{state[:port]}/"
      <> (if not is_nil(node_name), do: "_node/#{node_name}/", else: "")
      <> "_config/#{section}/#{key}")

    with {:ok, resp} <- HTTPClient.put(addr, Poison.encode!(value)),
         json_resp <- resp.body |> Poison.decode!
      do {:reply, {:ok, json_resp}, state}
      else e -> {:reply, transform_error(e), state}
    end
  end


  def handle_call({:ddoc_insert, ddoc, name, database}, _from, state) do
    with {:ok, resp} <- HTTPClient.put(
           "#{state[:hostname]}:#{state[:port]}/#{database}/_design/#{name}",
           Poison.encode!(ddoc)
         ),
         %{"ok" => true} = json_resp <- resp.body |> Poison.decode!
      do {:reply, {:ok, json_resp}, state}
      else e -> {:reply, transform_error(e), state}
    end
  end

  def handle_call({:ddoc_get, name, database, opts}, from, state) do
    handle_call({:document_get, "_design/#{name}", database, opts}, from, state)
  end

  def handle_call({:ddoc_delete, name, rev, database}, from, state) do
    handle_call({:document_delete, {"_design/#{name}", rev}, database}, from, state)
  end


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
    with {:ok, resp} <- HTTPClient.get("#{state[:hostname]}:#{state[:port]}/_uuids", [], params: [count: count]),
         %{"uuids" => uuids} <- resp.body |> Poison.decode!
      do {:ok, uuids}
      else e -> transform_error(e)
    end
  end

  defp transform_error(%{"error" => error, "reason" => reason}) do
    {:error, %CouchDBEx.Error{error: error, reason: reason}}
  end

  defp transform_error(e) do
    {:error, e}
  end

end
