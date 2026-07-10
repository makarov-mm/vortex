defmodule VortexField.Protocol do
  @moduledoc """
  Wire format for one velocity-field frame.

  The socket runs in `{packet, 4}` mode, so `:gen_tcp` prepends a 4-byte
  BIG-endian length header automatically. Everything below is the payload
  that header describes; all payload numbers are LITTLE-endian so the client
  can `memcpy` the field straight into a Metal texture with no byte-swapping.

      payload =
        <<
          w          :: uint16-le,   # grid width
          h          :: uint16-le,   # grid height
          frame_index:: uint32-le,   # monotonically increasing
          field      :: float32-le[ w * h * 2 ]   # row-major, interleaved (u, v)
        >>

  So a client reads: 4-byte BE length N -> N-byte payload -> parse header ->
  the remaining N-8 bytes are `w*h` (u,v) float32 pairs.
  """

  @spec encode_frame(pos_integer, pos_integer, non_neg_integer, iodata) :: iodata
  def encode_frame(w, h, frame_index, field_iodata) do
    [
      <<w::unsigned-little-16, h::unsigned-little-16, frame_index::unsigned-little-32>>,
      field_iodata
    ]
  end
end
