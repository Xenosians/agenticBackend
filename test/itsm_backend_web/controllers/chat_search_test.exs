defmodule ItsmBackendWeb.ChatSearchTest do
  @moduledoc """
  Searchable saved conversations (SRS 1.9 FR-078): one owner's chats are found
  by title or by the text of their saved turns, never another owner's and
  never an archived chat. The search reads durable records only.
  """
  use ItsmBackendWeb.ConnCase, async: false

  alias ItsmBackend.{Chats, Jobs}
  alias ItsmBackendWeb.AuthTestSupport

  setup do
    owner = AuthTestSupport.authenticated_identity!()
    other = AuthTestSupport.authenticated_identity!()
    marker = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    %{owner: owner, other: other, marker: marker}
  end

  test "finds the owner's chats by title and by saved message text", %{
    owner: owner,
    marker: marker
  } do
    {:ok, titled} = Chats.create(owner.user, %{"title" => "Printer #{marker} outage"})
    {:ok, untitled} = Chats.create(owner.user, %{"title" => "Morning requests"})
    turn!(owner, untitled, "Reset the VPN token for #{marker}")
    turn!(owner, untitled, "Nothing to see here")

    results = search!(owner, String.upcase(marker))
    ids = Enum.map(results, & &1["chat_id"])
    assert Enum.sort(ids) == Enum.sort([titled["chat_id"], untitled["chat_id"]])

    by_id = Map.new(results, &{&1["chat_id"], &1})
    assert by_id[titled["chat_id"]]["title"] == "Printer #{marker} outage"
    assert by_id[titled["chat_id"]]["matched"] == "title"
    assert by_id[untitled["chat_id"]]["matched"] == "message"
    # The excerpt is the matching saved turn, so the user can tell results apart.
    assert by_id[untitled["chat_id"]]["excerpt"] == "Reset the VPN token for #{marker}"
  end

  test "never returns another owner's or an archived chat", %{
    owner: owner,
    other: other,
    marker: marker
  } do
    {:ok, foreign} = Chats.create(other.user, %{"title" => "Foreign #{marker}"})
    turn!(other, foreign, "Foreign message #{marker}")
    {:ok, archived} = Chats.create(owner.user, %{"title" => "Archived #{marker}"})
    {:ok, _} = Chats.archive(owner.user, archived["chat_id"])

    assert search!(owner, marker) == []
    assert [%{"chat_id" => foreign_id}] = search!(other, marker)
    assert foreign_id == foreign["chat_id"]
  end

  test "queries are bounded and an empty query is rejected", %{owner: owner} do
    assert owner
           |> conn_for()
           |> get("/api/v1/chats/search", %{"q" => "  "})
           |> json_response(400) ==
             %{"error" => "search_query_required"}

    long = String.duplicate("a", 201)

    assert owner
           |> conn_for()
           |> get("/api/v1/chats/search", %{"q" => long})
           |> json_response(400) ==
             %{"error" => "search_query_too_long"}
  end

  test "requires a signed-in session", %{marker: marker} do
    assert build_conn() |> get("/api/v1/chats/search", %{"q" => marker}) |> json_response(401)
  end

  test "search text is matched literally, not as a query language", %{
    owner: owner,
    marker: marker
  } do
    {:ok, chat} = Chats.create(owner.user, %{"title" => "Quotes #{marker}"})
    turn!(owner, chat, "Path C:\\temp\\#{marker}' OR 1=1 -- 100%")

    assert [%{"chat_id" => id}] = search!(owner, "#{marker}' OR 1=1 -- 100%")
    assert id == chat["chat_id"]
    assert search!(owner, "%#{marker}%") == []
  end

  defp turn!(identity, chat, message) do
    {:ok, _job} =
      Jobs.create(%{
        user_id: identity.user["user_id"],
        conversation_id: chat["chat_id"],
        message: message
      })
  end

  defp search!(identity, query) do
    identity
    |> conn_for()
    |> get("/api/v1/chats/search", %{"q" => query})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp conn_for(identity),
    do: build_conn() |> AuthTestSupport.bearer_conn(identity.auth.raw_token)
end
