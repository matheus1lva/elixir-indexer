defmodule ElixirIndex.Utils do
  def hex_to_integer("0x" <> hex), do: String.to_integer(hex, 16)
  def hex_to_integer(hex) when is_binary(hex), do: String.to_integer(hex, 16)
  def hex_to_integer(int) when is_integer(int), do: int
  def hex_to_integer(nil), do: nil

  def pad_hex(nil), do: nil
  def pad_hex("0x" <> hex), do: "0x" <> String.pad_leading(hex, 64, "0")
  # Keep already correct length or handle generic
  def pad_hex(hex) when is_binary(hex), do: hex
end
