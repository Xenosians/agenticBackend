defmodule ItsmBackendWeb.HealthController do
  use ItsmBackendWeb, :controller

  def index(conn, _params) do
    json(conn, %{
      status: "ok",
      service: "itsm_backend"
    })
  end
end
