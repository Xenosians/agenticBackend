defmodule ItsmBackend.Jobs.SurrealStore do
  @moduledoc """
  SurrealDB persistence adapter for AI jobs.

  Handles durable create, read, update, queue claiming,
  and compare-and-set recovery operations.
  """

  alias ItsmBackend.Jobs.Job
  alias ItsmBackend.Surreal

  @table "job"

  # ------------------------------------------------------------
  # Queue claiming
  # ------------------------------------------------------------

  @spec claim_oldest(pos_integer()) ::
          {:ok, Job.t() | nil}
          | {:error, term()}
  def claim_oldest(lease_seconds \\ 300)

  def claim_oldest(lease_seconds)
      when is_integer(lease_seconds) and
             lease_seconds > 0 do
    claimed_at =
      DateTime.utc_now()
      |> DateTime.truncate(:microsecond)

    lease_expires_at =
      DateTime.add(
        claimed_at,
        lease_seconds,
        :second
      )

    statement = """
    UPDATE (
      SELECT id, created_at
      FROM job
      WHERE status = "pending"
      ORDER BY created_at ASC
      LIMIT 1
    )
    SET
      status = "processing",
      attempts = attempts + 1,
      claimed_at = $claimed_at,
      lease_expires_at = $lease_expires_at
    RETURN AFTER;
    """

    params = %{
      "claimed_at" =>
        DateTime.to_iso8601(
          claimed_at
        ),
      "lease_expires_at" =>
        DateTime.to_iso8601(
          lease_expires_at
        )
    }

    with {:ok, response} <-
           Surreal.query(
             statement,
             params
           ),
         {:ok, result} <-
           extract_result(response) do
      case result do
        [] ->
          {:ok, nil}

        nil ->
          {:ok, nil}

        [record]
        when is_map(record) ->
          deserialize(record)

        record
        when is_map(record) ->
          deserialize(record)

        other ->
          {:error,
           {
             :unexpected_claim_result,
             other
           }}
      end
    end
  end

  def claim_oldest(lease_seconds) do
    {:error,
     {
       :invalid_lease_seconds,
       lease_seconds
     }}
  end

  # ------------------------------------------------------------
  # Compare-and-set processing failure
  # ------------------------------------------------------------

  @spec fail_processing_if_current(
          Job.t(),
          String.t()
        ) ::
          {:ok, Job.t() | nil}
          | {:error, term()}
  def fail_processing_if_current(
        %Job{
          status: "processing"
        } = job,
        error
      )
      when is_binary(error) do
    failed_job =
      Job.put_error(
        job,
        error
      )

    with {:ok, failed_job} <-
           Job.transition(
             failed_job,
             "failed"
           ) do
      statement = """
      UPDATE type::record($table, $id)
      SET
        status = "failed",
        error = $error,
        completed_at = $completed_at,
        lease_expires_at = $cleared_lease
      WHERE
        status = "processing"
        AND attempts = $attempts
        AND claimed_at = $claimed_at
        AND lease_expires_at = $expected_lease_expires_at
      RETURN AFTER;
      """

      params = %{
        "table" => @table,
        "id" => job.id,
        "attempts" => job.attempts,
        "claimed_at" =>
          encode_datetime(
            job.claimed_at
          ),
        "expected_lease_expires_at" =>
          encode_datetime(
            job.lease_expires_at
          ),
        "error" => failed_job.error,
        "completed_at" =>
          encode_datetime(
            failed_job.completed_at
          ),
        "cleared_lease" => nil
      }

      with {:ok, response} <-
             Surreal.query(
               statement,
               params
             ),
           {:ok, result} <-
             extract_result(response) do
        case result do
          nil ->
            {:ok, nil}

          [] ->
            {:ok, nil}

          record
          when is_map(record) ->
            deserialize(record)

          [record]
          when is_map(record) ->
            deserialize(record)

          other ->
            {:error,
             {
               :unexpected_recovery_result,
               other
             }}
        end
      end
    end
  end

  def fail_processing_if_current(
        %Job{} = job,
        _error
      ) do
    {:error,
     {
       :job_not_processing,
       job.status
     }}
  end

  # ------------------------------------------------------------
  # Create
  # ------------------------------------------------------------

  @spec create(Job.t()) ::
          {:ok, Job.t()}
          | {:error, term()}
  def create(%Job{} = job) do
    statement = """
    CREATE ONLY type::record($table, $id)
    CONTENT $data
    RETURN AFTER;
    """

    params = %{
      "table" => @table,
      "id" => job.id,
      "data" => serialize(job)
    }

    with {:ok, response} <-
           Surreal.query(
             statement,
             params
           ),
         {:ok, record} <-
           extract_single_result(
             response
           ),
         {:ok, stored_job} <-
           deserialize(record) do
      {:ok, stored_job}
    end
  end

  # ------------------------------------------------------------
  # Get
  # ------------------------------------------------------------

  @spec get(String.t()) ::
          {:ok, Job.t()}
          | {:error, :not_found | term()}
  def get(job_id)
      when is_binary(job_id) do
    statement = """
    SELECT *
    FROM ONLY type::record($table, $id);
    """

    params = %{
      "table" => @table,
      "id" => job_id
    }

    with {:ok, response} <-
           Surreal.query(
             statement,
             params
           ),
         {:ok, result} <-
           extract_result(response) do
      case result do
        nil ->
          {:error, :not_found}

        [] ->
          {:error, :not_found}

        record
        when is_map(record) ->
          deserialize(record)

        [record]
        when is_map(record) ->
          deserialize(record)

        other ->
          {:error,
           {
             :unexpected_job_result,
             other
           }}
      end
    end
  end

  def get(job_id) do
    {:error,
     {
       :invalid_job_id,
       job_id
     }}
  end

  # ------------------------------------------------------------
  # Update
  # ------------------------------------------------------------

  @spec update(Job.t()) ::
          {:ok, Job.t()}
          | {:error, term()}
  def update(%Job{} = job) do
    statement = """
    UPDATE ONLY type::record($table, $id)
    CONTENT $data
    RETURN AFTER;
    """

    params = %{
      "table" => @table,
      "id" => job.id,
      "data" => serialize(job)
    }

    with {:ok, response} <-
           Surreal.query(
             statement,
             params
           ),
         {:ok, record} <-
           extract_single_result(
             response
           ),
         {:ok, stored_job} <-
           deserialize(record) do
      {:ok, stored_job}
    end
  end

  # ------------------------------------------------------------
  # Serialization
  # ------------------------------------------------------------

  defp serialize(
         %Job{} = job
       ) do
    %{
      "job_id" => job.id,
      "user_id" => job.user_id,
      "conversation_id" =>
        job.conversation_id,
      "message" => job.message,
      "status" => job.status,
      "attempts" => job.attempts,
      "created_at" =>
        encode_datetime(
          job.created_at
        ),
      "claimed_at" =>
        encode_datetime(
          job.claimed_at
        ),
      "lease_expires_at" =>
        encode_datetime(
          job.lease_expires_at
        ),
      "completed_at" =>
        encode_datetime(
          job.completed_at
        ),
      "selected_agent" =>
        job.selected_agent,
      "proposed_tool" =>
        job.proposed_tool,
      "result" => job.result,
      "error" => job.error,
      "notification_status" =>
        job.notification_status
    }
  end

  # ------------------------------------------------------------
  # Deserialization
  # ------------------------------------------------------------

  defp deserialize(record)
       when is_map(record) do
    with {:ok, created_at} <-
           decode_datetime(
             Map.get(
               record,
               "created_at"
             )
           ),
         {:ok, claimed_at} <-
           decode_datetime(
             Map.get(
               record,
               "claimed_at"
             )
           ),
         {:ok, lease_expires_at} <-
           decode_datetime(
             Map.get(
               record,
               "lease_expires_at"
             )
           ),
         {:ok, completed_at} <-
           decode_datetime(
             Map.get(
               record,
               "completed_at"
             )
           ) do
      {:ok,
       %Job{
         id:
           Map.fetch!(
             record,
             "job_id"
           ),
         user_id:
           Map.fetch!(
             record,
             "user_id"
           ),
         conversation_id:
           Map.get(
             record,
             "conversation_id"
           ),
         message:
           Map.fetch!(
             record,
             "message"
           ),
         status:
           Map.fetch!(
             record,
             "status"
           ),
         attempts:
           Map.get(
             record,
             "attempts",
             0
           ),
         created_at: created_at,
         claimed_at: claimed_at,
         lease_expires_at:
           lease_expires_at,
         completed_at:
           completed_at,
         selected_agent:
           Map.get(
             record,
             "selected_agent"
           ),
         proposed_tool:
           Map.get(
             record,
             "proposed_tool"
           ),
         result:
           Map.get(
             record,
             "result"
           ),
         error:
           Map.get(
             record,
             "error"
           ),
         notification_status:
           Map.get(
             record,
             "notification_status",
             "not_required"
           )
       }}
    end
  rescue
    error ->
      {:error,
       {
         :invalid_job_record,
         error
       }}
  end

  # ------------------------------------------------------------
  # Surreal response helpers
  # ------------------------------------------------------------

  defp extract_result([
         %{
           "result" => result,
           "status" => "OK"
         }
         | _
       ]) do
    {:ok, result}
  end

  defp extract_result(response) do
    {:error,
     {
       :unexpected_surreal_response,
       response
     }}
  end

  defp extract_single_result(
         response
       ) do
    with {:ok, result} <-
           extract_result(response) do
      case result do
        record
        when is_map(record) ->
          {:ok, record}

        [record]
        when is_map(record) ->
          {:ok, record}

        nil ->
          {:error, :not_found}

        [] ->
          {:error, :not_found}

        other ->
          {:error,
           {
             :unexpected_single_result,
             other
           }}
      end
    end
  end

  # ------------------------------------------------------------
  # Datetime helpers
  # ------------------------------------------------------------

  defp encode_datetime(nil),
    do: nil

  defp encode_datetime(
         %DateTime{} = datetime
       ) do
    DateTime.to_iso8601(
      datetime
    )
  end

  defp decode_datetime(nil),
    do: {:ok, nil}

  defp decode_datetime(
         %DateTime{} = datetime
       ) do
    {:ok, datetime}
  end

  defp decode_datetime(value)
       when is_binary(value) do
    case DateTime.from_iso8601(
           value
         ) do
      {:ok, datetime, _offset} ->
        {:ok, datetime}

      {:error, reason} ->
        {:error,
         {
           :invalid_datetime,
           value,
           reason
         }}
    end
  end
end
