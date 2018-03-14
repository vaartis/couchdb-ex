defmodule CouchDBEx.Worker do
  use GenServer

  @moduledoc """
  ## TODO:

  - [ ] `_stats`
  - [ ] `_scheduler`
  - [ ] `_session` - cookie session
  """

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(args) do
    args = Keyword.merge(
      [
        hostname: "http://localhost",
        port: 5984
      ],
      args
    )

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
        e -> {:reply, e, state}
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

  @doc """
  ## Options

  * `replicas` - number of replicas for this database, defaults to 3
  * `shards` - number of shards for this database, defaults to 8
  """
  @impl true
  def handle_call({:db_create, db_name, opts}, _from, state) do
    default_opts = [replicas: 3, shards: 8]
    final_opts = Keyword.merge(default_opts, opts)

    with {:ok, resp} <- HTTPoison.put(
           "#{state[:hostname]}:#{state[:port]}/#{db_name}",
           [],
           %{n: final_opts[:replicas], q: final_opts[:shards]}
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


  @doc """
  Documents can have an `_id` field, in this case database will no attemt to generate a new one.
  Inserting a list of documents will count as a bulk insert. This function error if documents have a `_rev`
  field, this should be done in a separate function.

  ## TODO:

  * batch mode
  """
  @impl true
  def handle_call({:document_insert, database, document_or_documents}, _from, state) do
    # A bulk insert
    if is_list(document_or_documents) do
      documents = document_or_documents

      if not Enum.any?(documents, fn d -> Map.has_key?(d, "_rev") end) do
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
        {:reply, {:error, "Documents contain the `_rev` field, `update` function should be used to update documents (TODO)"}, state}
      end
    else
      document = document_or_documents

      # If document has a _rev field, it's an update, treat this as an error
      # TODO: create a function for updating
      if not Map.has_key?(document, "_rev") do
        with {:ok, resp} <- HTTPoison.post(
               "#{state[:hostname]}:#{state[:port]}/#{database}",
               Poison.encode!(document),
               [{"Content-Type", "application/json"}]
             ),
             %{"ok" => true, "id" => id, "rev" => rev} <- resp.body |> Poison.decode!
          do {:reply, {:ok, [id: id, rev: rev]}, state}
          else e -> {:reply, {:error, e}, state}
        end
      else
        {:reply, {:error, "Document contains the `_rev` field, `update` function should be used to update documents (TODO)"}, state}
      end
    end
  end

  @doc """
  ## Options

  * `attachments` - should the request return full information about attachments
                    (includes full base64 encoded attachments into the request), `false` by default
  """
  @impl true
  def handle_call({:document_get, database, id, opts}, _from, state) do
    default_opts = [attachmets: false]
    final_opts = Keyword.merge(default_opts, opts)

    with {:ok, resp} <- HTTPoison.get(
           "#{state[:hostname]}:#{state[:port]}/#{database}/#{id}",
           [{"Accept", "application/json"}], # This header is required, because if we request attachments, it'll return JSON as binary data and cause an error
           params: [attachments: final_opts[:attachments]]
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

  @doc """
  ## Options

  * `limit` - maximum number of results returned. Default is 25
  * `skip` - skip the first ‘n’ results
  * `sort` – an array following sort syntax
  * `fields` – an array specifying which fields of each object should be returned.
               If it is omitted, the entire object is returned. More information provided in the section on filtering fields
  * `use_index` - instruct a query to use a specific index. Specified either as "<design_document>" or ["<design_document>", "<index_name>"]
  * `r` - Read quorum needed for the result. This defaults to 1, in which case the document found in the index is returned.
          If set to a higher value, each document is read from at least that many replicas before it is returned in the results. This is likely to take more time
          than using only the document stored locally with the index
  * `bookmark` - a string that enables you to specify which page of results you require. Used for paging through result sets. Every query returns an opaque string
                 under the bookmark key that can then be passed back in a query to get the next page of results.
                 If any part of the selector query changes between requests, the results are undefined, defaults to nil
  * `update` - whether to update the index prior to returning the result. Default is true
  * `stable` - whether or not the view results should be returned from a “stable” set of shards
  * `stale` - combination of `update: false` and `stable: true` options. Possible options: "ok", false (default)
  * `execution_stats` - include execution statistics in the query response. Default: false

  Options and their descriptions are taken from [here](http://docs.couchdb.org/en/2.1.1/api/database/find.html)
  """
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
  ## Options

  * `content_type` - content type of the attachment in the standard format (e.g. `text/plain`), this option will set the
                     `Content-Type` header for the request.
  """
  @impl true
  def handle_call({:attachment_upload, database, id, {attachment_name, attachment_bindata}, rev, opts}, _from, state) do
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


  @doc """
  ## Options

  * `create_target` - should the target of replication be created or not (defaults to `false`)
  * `continuous` - should the replication be continuous
  * `cancel` - cancel the continuous replication (note that cancel request should be identical to the
                replication request, except the addition of `cancel`)
  """
  def handle_call({:replicate, source, target, opts}, _from, state) do
    default_opts = [
      create_target: false,
      continuous: false,
      cancel: false
    ]

    final_opts = Keyword.merge(default_opts, opts)

    with {:ok, resp} <- HTTPoison.post(
           "#{state[:hostname]}:#{state[:port]}/_replicate",
           %{
             source: source,
             target: target,
             create_target: final_opts[:create_target],
             continuous: final_opts[:continuous],
             cancel: final_opts[:cancel]
           } |> Poison.encode!,
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


  defp uuid_get_impl(count, state) do
    with {:ok, resp} <- HTTPoison.get("#{state[:hostname]}:#{state[:port]}/_uuids", [], params: [count: count]),
         %{"uuids" => uuids} <- resp.body |> Poison.decode!
      do {:ok, uuids}
      else e -> {:error, e}
    end
  end

end
