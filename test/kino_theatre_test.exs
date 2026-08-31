defmodule KinoTheatreTest do
  use ExUnit.Case
  doctest KinoTheatre

  test "greets the world" do
    assert KinoTheatre.hello() == :world
  end
end
