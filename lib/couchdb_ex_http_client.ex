defmodule CouchDBEx.HTTPClient do
  use HTTPoison.Base

  alias CouchDBEx.Worker.AuthAgent

  def process_request_headers(headers) do
    basic_auth = Agent.get(AuthAgent, fn st -> st[:basic_auth] end)

    headers = unless is_nil(basic_auth) do
      [{"Authorization", "Basic #{basic_auth}"} | headers]
    else
      headers
    end

    headers
  end

end
