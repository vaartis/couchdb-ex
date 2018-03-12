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
      else
        %{"error" => er, "reason" => reason} -> {:reply, {:error, [error: er, reason: reason]}, state}
    end
  end

  @impl true
  def handle_call({:db_delete, db_name}, _from, state) do
    with {:ok, resp} <- HTTPoison.delete("#{state[:hostname]}:#{state[:port]}/#{db_name}"),
         %{"ok" => true} <- resp.body |> Poison.decode!
      do {:reply, :ok, state}
      else
        %{"error" => er, "reason" => reason} -> {:reply, {:error, [error: er, reason: reason]}, state}
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
  ## Options

  * `id` - manyully provide a UUID insead of getting it from `/_uuids`
  """
  @impl true
  def handle_call({:document_insert, database, document, opts}, _from, state) do
    # If document has a _rev field, it's an update, treat this as an error
    # TODO: create a function for updating
    if not Map.has_key?(document, "_rev") do
      with {:ok, [uuid]} <- if(Keyword.has_key?(opts, :id), do: {:ok, [opts[:id]]}, else: uuid_get_impl(1, state)),
             {:ok, resp} <- HTTPoison.put("#{state[:hostname]}:#{state[:port]}/#{database}/#{uuid}", Poison.encode!(document)),
             %{"ok" => true, "id" => id, "rev" => rev} <- resp.body |> Poison.decode!
        do {:reply, {:ok, [id: id, rev: rev]}, state}
        else e -> {:reply, e, state}
      end
    else
      {:reply, {:error, "Document contains the `_rev` field, `update` function should be used to update documents (TODO)"}, state}
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
        {:reply, {:error, [error: json_resp["error"], reason: json_resp["reason"]]}, state}
      end
    else e -> {:reply, e, state}
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
