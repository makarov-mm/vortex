defmodule VortexField.Protocol do
  @moduledoc """
  Wire format for one frame.

  The socket runs in `{packet, 4}` mode, so `:gen_tcp` prepends a 4-byte
  BIG-endian length header automatically. Everything below is the payload it
  describes; all payload numbers are LITTLE-endian so the client can copy the
  field straight into a Metal texture with no byte-swapping.

      payload =
        <<
          w           :: uint16-le,   # grid width
          h           :: uint16-le,   # grid height
          frame_index :: uint32-le,   # monotonically increasing
          vortex_count:: uint16-le,   # number of vortex markers that follow the field
          _reserved   :: uint16-le,   # 0 (keeps the field 4-byte aligned at offset 12)
          field       :: float32-le[ w * h * 2 ],      # row-major, interleaved (u, v)
          vortices    :: float32-le[ vortex_count*3 ]  # (x, y, gamma_eff) per vortex
        >>

  Header is 12 bytes. Field starts at offset 12; the vortex list starts at
  `12 + w*h*2*4`.
  """

  @doc "Build the {count, iodata} for the trailing vortex-marker list."
  @spec encode_vortices([{float, float, float}]) :: {non_neg_integer, iodata}
  def encode_vortices(eff) do
    {count, rev} =
      Enum.reduce(eff, {0, []}, fn {x, y, g}, {n, acc} ->
        {n + 1, [<<x::float-little-32, y::float-little-32, g::float-little-32>> | acc]}
      end)

    {count, Enum.reverse(rev)}
  end

  @spec encode_frame(pos_integer, pos_integer, non_neg_integer, non_neg_integer, iodata, iodata) ::
          iodata
  def encode_frame(w, h, frame_index, vortex_count, field_iodata, vortices_iodata) do
    [
      <<w::unsigned-little-16, h::unsigned-little-16, frame_index::unsigned-little-32,
        vortex_count::unsigned-little-16, 0::unsigned-little-16>>,
      field_iodata,
      vortices_iodata
    ]
  end
end
