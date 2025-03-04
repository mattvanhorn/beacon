defmodule Beacon.Types.Binary do
  @moduledoc """
  Store Elixir terms into the database as binary.

  Used to store and load layout and page snapshots.
  """

  use Ecto.Type

  def type, do: :binary

  def cast(:any, term), do: {:ok, term}
  def cast(term), do: {:ok, term}

  def load(binary) when is_binary(binary) do
    {:ok, :erlang.binary_to_term(binary)}
  end

  def dump(term) do
    {:ok, :erlang.term_to_binary(term)}
  end
end
