defmodule CouchDBEx.Worker.AuthServer do
  use GenServer

  @moduledoc false

  ## Client

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  def cookie_data do
    GenServer.call(__MODULE__, :cookie_data)
  end

  def basic_auth_data do
    GenServer.call(__MODULE__, :basic_auth_data)
  end

  def auth_method do
    GenServer.call(__MODULE__, :auth_method)
  end

  ## Server

  @impl true
  def init(state) do
    unless is_nil(state[:auth_method]) do
      if is_nil(state[:username]) or is_nil(state[:password]) do
        {:error, :name_or_password_nil}
      else
        case state[:auth_method] do
          :basic ->
            {
              :ok,
              %{
                auth_method: :basic,
                data: Base.encode64("#{state[:username]}:#{state[:password]}")
              }
            }

          :cookie ->
            # Set the default session time to 9 minutes just to be safe
            session_mins = Keyword.get(state, :cookie_session_minutes, 9)

            # Create a session right after module startup
            send(__MODULE__, :renew_cookie_session)

            {
              :ok,
              state |> Keyword.put(:cookie_session_minutes, session_mins)
            }

          _ -> {:error, :unknown_auth_method}
        end
      end
    end
  end

  @impl true
  def handle_call(:basic_auth_data, _from, state) do
    if state[:auth_method] == :basic, do: {:reply, state[:data], state}, else: nil
  end

  @impl true
  def handle_call(:cookie_data, _from, state) do
    if state[:auth_method] == :cookie, do: {:reply, state[:data], state}, else: nil
  end

  @impl true
  def handle_call(:auth_method, _from, state) do
    {:reply, state[:auth_method], state}
  end

  @impl true
  def handle_info(:renew_cookie_session, state) do
    with {:ok, resp} <- HTTPoison.post(
           "#{state[:hostname]}:#{state[:port]}/_session",
           %{
             name: state[:username],
             password: state[:password]
           } |> Poison.encode!,
           [{"Content-Type", "application/json"}]
         ),
         %{"ok" => true} <- (resp.body |> Poison.decode!),
         {_, cookie} <- Enum.find(resp.headers, fn {nm, _} -> nm == "Set-Cookie" end) do

      # Schedule the next renewal
      Process.send_after(__MODULE__, :renew_cookie_session, 1000 * 60 * state[:cookie_session_minutes])

      # Update the cookie
      {:noreply, state |> Keyword.put(:data, cookie)}
    end
  end
end
