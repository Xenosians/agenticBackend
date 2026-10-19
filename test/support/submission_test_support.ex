defmodule ItsmBackend.SubmissionTestSupport do
  @moduledoc false

  def identity do
    <<a::binary-size(8), b::binary-size(4), _::binary-size(1), c::binary-size(3),
      _::binary-size(1), d::binary-size(3), e::binary-size(12)>> =
      :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

    Enum.join([a, b, "4" <> c, "8" <> d, e], "-")
  end
end
