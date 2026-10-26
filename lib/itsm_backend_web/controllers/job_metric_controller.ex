defmodule ItsmBackendWeb.JobMetricController do
  use ItsmBackendWeb, :controller
  use ItsmBackendWeb.RequestContract
  alias ItsmBackend.Jobs.{InferenceMetric, Operations}
  alias ItsmBackend.RuntimeConfig

  request_contract(:create,
    required_body: InferenceMetric.required_fields(),
    optional_body: InferenceMetric.optional_fields()
  )

  def create(conn, %{"id" => job_id}) do
    if authorized?(conn) do
      case Operations.record(job_id, conn.body_params) do
        {:ok, metric, :created} ->
          conn |> put_status(:created) |> json(%{metric: metric})

        {:ok, metric, :existing} ->
          json(conn, %{metric: metric})

        {:error, :invalid_metric} ->
          conn |> put_status(:unprocessable_entity) |> json(%{error: "invalid_metric"})

        {:error, :not_found} ->
          conn |> put_status(:not_found) |> json(%{error: "job_not_found"})

        {:error, reason} when reason in [:stale_attempt, :metric_conflict] ->
          conn |> put_status(:conflict) |> json(%{error: Atom.to_string(reason)})

        _ ->
          conn |> put_status(:service_unavailable) |> json(%{error: "metric_outcome_unknown"})
      end
    else
      conn |> put_status(:unauthorized) |> json(%{error: "unauthorized"})
    end
  end

  defp authorized?(conn) do
    expected = RuntimeConfig.internal_job_token!()
    provided = get_req_header(conn, "x-internal-token") |> List.first()

    is_binary(provided) and byte_size(provided) == byte_size(expected) and
      Plug.Crypto.secure_compare(provided, expected)
  end
end
