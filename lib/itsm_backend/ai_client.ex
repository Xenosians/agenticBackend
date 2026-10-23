defmodule ItsmBackend.AIClient do
  @moduledoc """
  Behaviour and compatibility boundary for Phoenix -> AI calls.

  Durable job execution has three protocol shapes:

    * execute_job/4 for legacy/no-context callers
    * execute_job/5 for bounded conversation context
    * execute_job/6 for a persisted requested workflow binding

  Queue workers should call dispatch_job/7 instead of probing callback
  availability themselves.  This keeps compatibility policy centralized and
  refuses to silently drop non-empty context when a client lacks execute_job/5.
  """

  @callback run(
              user_id :: String.t(),
              message :: String.t()
            ) ::
              {:ok, map()}
              | {:error, term()}

  @callback execute_job(
              job_id :: String.t(),
              attempt :: pos_integer(),
              user_id :: String.t(),
              message :: String.t()
            ) ::
              {:ok, map()}
              | {:error, term()}

  @callback execute_job(
              job_id :: String.t(),
              attempt :: pos_integer(),
              user_id :: String.t(),
              message :: String.t(),
              context :: list()
            ) ::
              {:ok, map()}
              | {:error, term()}

  @callback execute_job(String.t(), pos_integer(), String.t(), String.t(), list(), map() | nil) ::
              {:ok, map()} | {:error, term()}

  @optional_callbacks execute_job: 5, execute_job: 6

  @spec dispatch_job(
          module(),
          String.t(),
          pos_integer(),
          String.t(),
          String.t(),
          list(),
          map() | nil
        ) ::
          {:ok, map()} | {:error, term()}
  def dispatch_job(client, job_id, attempt, user_id, message, context, nil) do
    dispatch_job(client, job_id, attempt, user_id, message, context)
  end

  def dispatch_job(client, job_id, attempt, user_id, message, context, workflow_binding) do
    with {:ok, _} <-
           ItsmBackend.AIClient.JobContract.build_execute_request(
             job_id,
             attempt,
             user_id,
             message,
             context,
             workflow_binding
           ) do
      if function_exported?(client, :execute_job, 6),
        do: client.execute_job(job_id, attempt, user_id, message, context, workflow_binding),
        else: {:error, {:ai_client_missing_workflow_callback, client}}
    end
  end

  @callback approve(approval_id :: String.t()) ::
              {:ok, map()}
              | {:error, term()}

  @callback reject(approval_id :: String.t()) ::
              {:ok, map()}
              | {:error, term()}

  @callback health() ::
              {:ok, map()}
              | {:error, term()}

  @callback ready() ::
              {:ok, map()}
              | {:error, term()}

  @callback integrations() ::
              {:ok, map()}
              | {:error, term()}

  @spec dispatch_job(
          module(),
          String.t(),
          pos_integer(),
          String.t(),
          String.t(),
          list()
        ) ::
          {:ok, map()}
          | {:error, term()}
  def dispatch_job(
        client,
        job_id,
        attempt,
        user_id,
        message,
        context
      )
      when is_atom(client) and
             is_binary(job_id) and
             is_integer(attempt) and
             attempt > 0 and
             is_binary(user_id) and
             is_binary(message) and
             is_list(context) do
    cond do
      function_exported?(
        client,
        :execute_job,
        5
      ) ->
        client.execute_job(
          job_id,
          attempt,
          user_id,
          message,
          context
        )

      context == [] and
          function_exported?(
            client,
            :execute_job,
            4
          ) ->
        client.execute_job(
          job_id,
          attempt,
          user_id,
          message
        )

      true ->
        {:error,
         {
           :ai_client_missing_context_callback,
           client
         }}
    end
  end

  def dispatch_job(
        client,
        job_id,
        attempt,
        user_id,
        message,
        context
      ) do
    {:error,
     {
       :invalid_ai_dispatch,
       client,
       job_id,
       attempt,
       user_id,
       message,
       context
     }}
  end
end
