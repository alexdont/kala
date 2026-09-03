defmodule KalaTest do
  use ExUnit.Case

  test "config lang defaults sensibly" do
    assert is_binary(Kala.Config.lang())
  end
end
