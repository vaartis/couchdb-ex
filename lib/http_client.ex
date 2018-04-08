defmodule CouchDBEx.HTTPClient do
  use HTTPoison.Base

  alias CouchDBEx.Worker.AuthServer

  def process_request_options(options) do
    # Cookies are handles by hackney

    if AuthServer.auth_method == :cookie do
      # Update the hackney options if there are any
      if Keyword.has_key?(options, :hackney) do
        put_in(
          options[:hackney],
          Keyword.put(options[:hackney], :cookie, AuthServer.cookie_data)
        )
      else
        Keyword.put(options, :hackney, [cookie: AuthServer.cookie_data])
      end
    else
      options
    end
  end

  def process_request_headers(headers) do
    # Bais auth requires to eplicitly set headers

    if AuthServer.auth_method == :basic do
      [{"Authorization", "Basic #{AuthServer.basic_auth_data}"} | headers]
    else
      headers
    end
  end

end
