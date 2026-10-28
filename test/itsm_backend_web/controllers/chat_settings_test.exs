defmodule ItsmBackendWeb.ChatSettingsTest do
  use ItsmBackendWeb.ConnCase, async: false

  alias ItsmBackend.{Chats, Jobs, Surreal}
  alias ItsmBackendWeb.AuthTestSupport

  setup do
    %{
      owner: AuthTestSupport.authenticated_identity!(),
      other: AuthTestSupport.authenticated_identity!()
    }
  end

  test "renames and pins only the selected chat, persisting a confirmed receipt", %{owner: owner} do
    id = owner.chat["chat_id"]
    updated = update!(owner, id, %{"title" => "  Network operations  ", "pinned" => true})
    assert updated["title"] == "Network operations"
    assert updated["pinned"] == true
    assert updated["chat_id"] == id
    assert {:ok, stored} = Chats.get_authorized(owner.user, id)
    assert stored["title"] == updated["title"]
    assert stored["pinned"] == true
    assert update!(owner, id, %{"pinned" => false})["title"] == "Network operations"
  end

  test "rejects empty, malformed and overlong updates without changing storage", %{owner: owner} do
    id = owner.chat["chat_id"]

    for payload <- [
          %{},
          %{"title" => "  "},
          %{"title" => 4},
          %{"title" => String.duplicate("é", 161)},
          %{"pinned" => "true"},
          %{"pinned" => nil}
        ] do
      assert conn_for(owner) |> patch("/api/v1/chats/#{id}", payload) |> json_response(422) ==
               %{"error" => "invalid_chat_update"}
    end

    assert {:error, :invalid_chat_update} = Chats.update(owner.user, id, %{"user_id" => "forged"})
    assert {:ok, stored} = Chats.get_authorized(owner.user, id)
    assert stored["title"] == owner.chat["title"]
    assert stored["pinned"] == false
  end

  test "rejects unauthenticated, foreign and archived chat updates", %{owner: owner, other: other} do
    id = owner.chat["chat_id"]
    assert build_conn() |> patch("/api/v1/chats/#{id}", %{"pinned" => true}) |> json_response(401)

    assert conn_for(other)
           |> patch("/api/v1/chats/#{id}", %{"pinned" => true})
           |> json_response(403)

    assert {:ok, _} = Chats.archive(owner.user, id)

    assert conn_for(owner)
           |> patch("/api/v1/chats/#{id}", %{"title" => "Restored"})
           |> json_response(404)

    assert {:ok, stored} = Chats.get_authorized(owner.user, id)
    assert stored["title"] == owner.chat["title"]
    assert stored["pinned"] == false
  end

  test "cookie PATCH requires the current owner's CSRF token", %{owner: owner} do
    path = "/api/v1/chats/#{owner.chat["chat_id"]}"

    cookie =
      build_conn()
      |> put_req_cookie(ItsmBackend.RuntimeConfig.auth!().cookie_name, owner.auth.raw_token)

    assert cookie |> patch(path, %{"pinned" => true}) |> json_response(403) == %{
             "error" => "csrf_failed"
           }

    saved =
      cookie
      |> put_req_header("x-csrf-token", owner.auth.csrf_token)
      |> patch(path, %{"pinned" => true})

    assert json_response(saved, 200)["chat"]["pinned"] == true
  end

  test "storage error, malformed receipt and lost acknowledgement remain unknown", %{owner: owner} do
    id = owner.chat["chat_id"]

    for fault <- [:http_500, :empty_result, :lost_response] do
      restore = ItsmBackendWeb.StorageFaultProxy.install!(fault, ~r/MERGE .*itsm_bound_/s)

      assert conn_for(owner)
             |> patch("/api/v1/chats/#{id}", %{"pinned" => true})
             |> json_response(503) ==
               %{"error" => "chat_update_outcome_unknown"}

      assert_receive {:storage_fault, ^fault}
      restore.()
      assert {:ok, stored} = Chats.get_authorized(owner.user, id)
      assert stored["pinned"] == (fault == :lost_response)
    end
  end

  test "automatic title storage failure does not hide an accepted durable submission", %{
    owner: owner
  } do
    {:ok, chat} = Chats.create(owner.user)
    restore = ItsmBackendWeb.StorageFaultProxy.install!(:http_500, ~r/title_source = "request"/)
    accepted = submit!(owner, chat["chat_id"], "A saved request whose title update failed")
    assert_receive {:storage_fault, :http_500}
    restore.()
    assert {:ok, job} = Jobs.get(accepted["job_id"])
    assert job.message == "A saved request whose title update failed"
    assert {:ok, stored} = Chats.get_authorized(owner.user, chat["chat_id"])
    assert stored["title"] == "New chat"
  end

  test "lists pinned chats first and reads legacy missing pinned as false", %{owner: owner} do
    {:ok, older} = Chats.create(owner.user, %{"title" => "Pinned older"})
    {:ok, newer} = Chats.create(owner.user, %{"title" => "Newer unpinned"})
    update!(owner, older["chat_id"], %{"pinned" => true})
    assert {:ok, rows} = Chats.list(owner.user)
    assert hd(rows)["chat_id"] == older["chat_id"]
    assert Enum.find(rows, &(&1["chat_id"] == newer["chat_id"]))["pinned"] == false

    assert {:ok, _} =
             Surreal.query("UPDATE type::record('chat', $id) UNSET pinned;", %{
               "id" => newer["chat_id"]
             })

    assert {:ok, legacy} = Chats.get_authorized(owner.user, newer["chat_id"])
    assert legacy["pinned"] == false

    assert {:ok, _} =
             Surreal.query("UPDATE type::record('chat', $id) SET pinned = 'invalid';", %{
               "id" => newer["chat_id"]
             })

    assert {:error, :invalid_chat_record} = Chats.get_authorized(owner.user, newer["chat_id"])
    assert {:error, :invalid_chat_record} = Chats.list(owner.user)
  end

  test "first saved request titles a default chat once and keeps manual renames", %{owner: owner} do
    {:ok, chat} = Chats.create(owner.user)
    id = chat["chat_id"]
    submit!(owner, id, "  Diagnose\n the    network  ")
    assert {:ok, stored} = Chats.get_authorized(owner.user, id)
    assert stored["title"] == "Diagnose the network"
    submit!(owner, id, "Ignore the earlier title")
    assert {:ok, stored} = Chats.get_authorized(owner.user, id)
    assert stored["title"] == "Diagnose the network"
    update!(owner, id, %{"title" => "New chat"})
    assert :ok = Chats.title_from_first_request(owner.user["user_id"], id)
    assert {:ok, renamed} = Chats.get_authorized(owner.user, id)
    assert renamed["title"] == "New chat"
    assert renamed["title_source"] == "manual"
  end

  test "title callback selects first durable request and cannot edit a foreign or archived chat",
       %{owner: owner, other: other} do
    {:ok, chat} = Chats.create(owner.user)
    id = chat["chat_id"]

    for message <- ["First saved request", "Later request"] do
      {:ok, _} =
        Jobs.create(%{user_id: owner.user["user_id"], conversation_id: id, message: message})
    end

    assert :ok = Chats.title_from_first_request(other.user["user_id"], id)
    assert {:ok, untitled} = Chats.get_authorized(owner.user, id)
    assert untitled["title"] == "New chat"
    assert :ok = Chats.title_from_first_request(owner.user["user_id"], id)
    assert {:ok, titled} = Chats.get_authorized(owner.user, id)
    assert titled["title"] == "First saved request"
    {:ok, archived} = Chats.create(owner.user)

    {:ok, _} =
      Jobs.create(%{
        user_id: owner.user["user_id"],
        conversation_id: archived["chat_id"],
        message: "Not a live thread"
      })

    {:ok, _} = Chats.archive(owner.user, archived["chat_id"])
    assert :ok = Chats.title_from_first_request(owner.user["user_id"], archived["chat_id"])
    assert {:ok, unchanged} = Chats.get_authorized(owner.user, archived["chat_id"])
    assert unchanged["title"] == "New chat"
  end

  test "title length is bounded in Unicode characters and request text stays literal", %{
    owner: owner
  } do
    {:ok, chat} = Chats.create(owner.user)
    submit!(owner, chat["chat_id"], String.duplicate("é", 200))
    assert {:ok, titled} = Chats.get_authorized(owner.user, chat["chat_id"])
    assert titled["title"] == String.duplicate("é", 160)

    renamed =
      update!(owner, chat["chat_id"], %{"title" => "x'; UPDATE chat SET pinned = true; --"})

    assert renamed["title"] == "x'; UPDATE chat SET pinned = true; --"
    assert {:ok, untouched} = Chats.get_authorized(owner.user, owner.chat["chat_id"])
    assert untouched["pinned"] == false
  end

  defp submit!(identity, chat_id, message) do
    conn_for(identity)
    |> post("/api/v1/jobs", %{"chat_id" => chat_id, "message" => message})
    |> json_response(202)
  end

  defp update!(identity, id, changes) do
    conn_for(identity)
    |> patch("/api/v1/chats/#{id}", changes)
    |> json_response(200)
    |> Map.fetch!("chat")
  end

  defp conn_for(identity),
    do: build_conn() |> AuthTestSupport.bearer_conn(identity.auth.raw_token)
end
