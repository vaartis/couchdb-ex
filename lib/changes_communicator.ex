defmodule CouchDBEx.Worker.ChangesCommunicator do
  use GenServer

  require Logger

  @moduledoc false

  # Client

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  # Server

  def init(args) do
    {:ok, _} =
      Supervisor.start_link([], strategy: :one_for_one, name: CouchDBEx.Worker.ChangesCommunicator.Supervisor)

    {:ok, Keyword.put(args, :watchers, %{})}
  end

  def handle_cast({:add_watcher, database, module_name, watcher_name, opts}, state) do
    if Enum.any?(opts, fn {e, _} -> e in [:feed, :heartbeet] end) do
      raise "Changing :feed or :heartbeet parameters is not supported"
    end

    {:ok, _} = Supervisor.start_child(
      CouchDBEx.Worker.ChangesCommunicator.Supervisor,
      %{
        id: watcher_name,
        start: {module_name, :start_link, [[name: watcher_name]]}
      }
    )

    default_opts = %{
      feed: "continuous",
      include_docs: true,
      since: "now",
      heartbeat: 25 # Sends an empty string to keep the connection alive every once in a while
    }

    pre_final_opts = Map.merge(default_opts, Enum.into(opts, %{}))

    maybe_body =
      %{
        doc_ids: pre_final_opts[:doc_ids],
        selector: pre_final_opts[:selector]
      }
      |> Enum.filter(fn {_, v} -> not is_nil(v) end)
      |> Enum.into(%{})
    maybe_body = if Enum.empty?(maybe_body), do: "", else: Poison.encode!(maybe_body)

    final_opts =
      pre_final_opts
      |> Map.delete(:doc_ids)
      |> Map.delete(:selector)

    {:ok, %HTTPoison.AsyncResponse{id: resp_id}} = HTTPoison.post(
      "#{state[:hostname]}:#{state[:port]}/#{database}/_changes",
      maybe_body,
      [{"Content-Type", "application/json"}],
      stream_to: self(),
      params: final_opts,
      recv_timeout: :infinity
    )

    state = put_in(state[:watchers][resp_id], watcher_name)

    {:noreply, state}
  end

  def handle_cast({:remove_watcher, watcher_name}, state) do
    Supervisor.terminate_child(CouchDBEx.Worker.ChangesCommunicator.Supervisor, watcher_name)
    Supervisor.delete_child(CouchDBEx.Worker.ChangesCommunicator.Supervisor, watcher_name)

    state =
      case Enum.find(state[:watchers], fn{_, nm} -> nm == watcher_name end) do
        {id, _} ->
          :hackney.close(id)

          Keyword.put(
            state,
            :watchers,
            Map.delete(state[:watchers], id)
          )
        nil -> state
      end

    {:noreply, state}
  end

  def handle_info(msg, state) do
    case msg do
      %HTTPoison.AsyncStatus{code: code, id: id} ->
        if code != 200 do
          modname = Map.fetch!(state[:watchers], id)

          Logger.error "Request to #{modname} finished with non-200 code (#{code})"
          Logger.error "Stopping the #{modname} watcher"

          GenServer.cast(__MODULE__, {:remove_watcher, modname})
        end

      %HTTPoison.AsyncHeaders{} -> :ok

      %HTTPoison.AsyncChunk{chunk: chunk, id: id} ->
        if chunk != "\n" do
          modname = Map.fetch!(state[:watchers], id)

          if not is_nil(modname) do
            # Chunks come in splitted by a newline symbol

            Enum.each(String.split(chunk, "\n", trim: true), fn ch ->
              send(modname, {:couchdb_change, Poison.decode!(ch)})
            end)
          else
            Logger.warn "Request id #{id} is not binded to any watcher, skipping"
          end
        end

      %HTTPoison.AsyncEnd{id: id} ->
        modname = Map.fetch!(state[:watchers], id)

        Logger.warn "Connection to #{modname} closed, stopping the watcher"

        GenServer.cast(__MODULE__, {:remove_watcher, modname})

      other -> Logger.warn "#{__MODULE__} got an unexpected message: #{inspect other}"
    end

    {:noreply, state}
  end
end
