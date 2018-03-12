defmodule CouchDBExTest do
  use ExUnit.Case
  doctest CouchDBEx

  test "greets the world" do
    assert CouchDBEx.hello() == :world
  end
end
