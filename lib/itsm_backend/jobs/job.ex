defmodule ItsmBackend.Jobs.Job do
  @moduledoc """
  Durable AI job domain model.

  This module owns job lifecycle semantics only.
  It does not know about SurrealDB, FastAPI, or Phoenix controllers.
  """

  @statuses [
    "pending",
    "processing",
    "waiting_approval",
    "completed",
    "failed"
  ]

  @terminal_statuses [
    "completed",
    "failed"
  ]

  @enforce_keys [
    :id,
    :user_id,
    :message,
    :status,
    :attempts,
    :created_at
  ]

  defstruct [
    :id,
    :user_id,
    :conversation_id,
    :message,
    :status,
    :attempts,
    :created_at,
    :claimed_at,
    :lease_expires_at,
    :completed_at,
    :selected_agent,
    :proposed_tool,
    :result,
    :error,
    notification_status: "not_required"
  ]

  @type t :: %__MODULE__{}

  @spec statuses() :: [String.t()]
  def statuses do
    @statuses
  end

  @spec new(map()) ::
          {:ok, t()}
          | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with {:ok, user_id} <-
           required_string(
             attrs,
             :user_id
           ),
         {:ok, message} <-
           required_string(
             attrs,
             :message
           ),
         {:ok, conversation_id} <-
           optional_string(
             attrs,
             :conversation_id
           ) do
      now = now()

      {:ok,
       %__MODULE__{
         id: generate_id(),
         user_id: user_id,
         conversation_id: conversation_id,
         message: message,
         status: "pending",
         attempts: 0,
         created_at: now,
         notification_status: "not_required"
       }}
    end
  end

  @spec claim(t(), pos_integer()) ::
          {:ok, t()}
          | {:error, term()}

  def claim(job, lease_seconds \\ 300)

  def claim(
        %__MODULE__{status: "pending"} = job,
        lease_seconds
      )
      when is_integer(lease_seconds) and
             lease_seconds > 0 do
    claimed_at = now()

    lease_expires_at =
      DateTime.add(
        claimed_at,
        lease_seconds,
        :second
      )

    {:ok,
     %{
       job
       | status: "processing",
         attempts: job.attempts + 1,
         claimed_at: claimed_at,
         lease_expires_at: lease_expires_at
     }}
  end

  def claim(
        %__MODULE__{} = job,
        _lease_seconds
      ) do
    {:error,
     {
       :job_not_pending,
       job.status
     }}
  end

  @spec transition(t(), String.t()) ::
          {:ok, t()}
          | {:error, term()}
  def transition(
        %__MODULE__{} = job,
        new_status
      )
      when new_status in @statuses do
    if allowed_transition?(
         job.status,
         new_status
       ) do
      {:ok,
       apply_transition(
         job,
         new_status
       )}
    else
      {:error,
       {
         :invalid_transition,
         job.status,
         new_status
       }}
    end
  end

  def transition(
        %__MODULE__{},
        new_status
      ) do
    {:error,
     {
       :invalid_status,
       new_status
     }}
  end

  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{status: status}) do
    status in @terminal_statuses
  end

  @spec put_result(t(), map()) :: t()
  def put_result(
        %__MODULE__{} = job,
        result
      )
      when is_map(result) do
    %{
      job
      | result: result,
        error: nil
    }
  end

  @spec put_error(t(), term()) :: t()
  def put_error(
        %__MODULE__{} = job,
        error
      ) do
    %{
      job
      | error: error
    }
  end

  @spec put_ai_metadata(
          t(),
          keyword()
        ) :: t()
  def put_ai_metadata(
        %__MODULE__{} = job,
        metadata
      )
      when is_list(metadata) do
    %{
      job
      | selected_agent:
          Keyword.get(
            metadata,
            :selected_agent,
            job.selected_agent
          ),
        proposed_tool:
          Keyword.get(
            metadata,
            :proposed_tool,
            job.proposed_tool
          )
    }
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = job) do
    Map.from_struct(job)
  end

  # ------------------------------------------------------------
  # State transitions
  # ------------------------------------------------------------

  defp allowed_transition?(
         "pending",
         "processing"
       ),
       do: true

  defp allowed_transition?(
         "pending",
         "failed"
       ),
       do: true

  defp allowed_transition?(
         "processing",
         "pending"
       ),
       do: true

  defp allowed_transition?(
         "processing",
         "waiting_approval"
       ),
       do: true

  defp allowed_transition?(
         "processing",
         "completed"
       ),
       do: true

  defp allowed_transition?(
         "processing",
         "failed"
       ),
       do: true

  defp allowed_transition?(
         "waiting_approval",
         "processing"
       ),
       do: true

  defp allowed_transition?(
         "waiting_approval",
         "completed"
       ),
       do: true

  defp allowed_transition?(
         "waiting_approval",
         "failed"
       ),
       do: true

  defp allowed_transition?(
         _current,
         _next
       ),
       do: false

  defp apply_transition(
         job,
         "pending"
       ) do
    %{
      job
      | status: "pending",
        claimed_at: nil,
        lease_expires_at: nil
    }
  end

  defp apply_transition(
         job,
         "waiting_approval"
       ) do
    %{
      job
      | status: "waiting_approval",
        lease_expires_at: nil
    }
  end

  defp apply_transition(
         job,
         status
       )
       when status in @terminal_statuses do
    %{
      job
      | status: status,
        lease_expires_at: nil,
        completed_at: now()
    }
  end

  defp apply_transition(
         job,
         status
       ) do
    %{
      job
      | status: status
    }
  end

  # ------------------------------------------------------------
  # Validation
  # ------------------------------------------------------------

  defp required_string(
         attrs,
         field
       ) do
    case fetch_value(
           attrs,
           field
         ) do
      value
      when is_binary(value) ->
        value = String.trim(value)

        if value == "" do
          {:error,
           {
             :invalid_field,
             field
           }}
        else
          {:ok, value}
        end

      _ ->
        {:error,
         {
           :invalid_field,
           field
         }}
    end
  end

  defp optional_string(
         attrs,
         field
       ) do
    case fetch_value(
           attrs,
           field
         ) do
      nil ->
        {:ok, nil}

      value
      when is_binary(value) ->
        value = String.trim(value)

        if value == "" do
          {:error,
           {
             :invalid_field,
             field
           }}
        else
          {:ok, value}
        end

      _ ->
        {:error,
         {
           :invalid_field,
           field
         }}
    end
  end

  defp fetch_value(
         attrs,
         field
       ) do
    Map.get(
      attrs,
      field,
      Map.get(
        attrs,
        Atom.to_string(field)
      )
    )
  end

  # ------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------

  defp generate_id do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end

  defp now do
    DateTime.utc_now()
    |> DateTime.truncate(:microsecond)
  end
end
