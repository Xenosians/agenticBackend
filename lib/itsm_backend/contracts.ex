defmodule ItsmBackend.Contracts do
  @moduledoc """
  Central access point for canonical Agentic ITSM contracts.

  Contract files are source/protocol invariants and are embedded into
  the compiled application. Deployment-specific configuration does not
  belong here.
  """

  @contracts_root Path.expand(
                    "../../contracts/v1",
                    __DIR__
                  )

  @contract_files %{
    error: "common/error.schema.json",
    tool_proposal: "common/tool-proposal.schema.json",
    job_create_request: "public/job-create-request.schema.json",
    job_create_response: "public/job-create-response.schema.json",
    job_response: "public/job-response.schema.json",
    ai_job_execute_request: "internal/ai-job-execute-request.schema.json",
    ai_job_accepted: "internal/ai-job-accepted.schema.json",
    ai_job_completion: "internal/ai-job-completion.schema.json",
    ai_job_completion_ack: "internal/ai-job-completion-ack.schema.json"
  }

  for relative_path <- Map.values(@contract_files) do
    @external_resource Path.join(
                         @contracts_root,
                         relative_path
                       )
  end

  @schemas Enum.into(
             @contract_files,
             %{},
             fn {name, relative_path} ->
               path =
                 Path.join(
                   @contracts_root,
                   relative_path
                 )

               schema =
                 path
                 |> File.read!()
                 |> Jason.decode!()

               {name, schema}
             end
           )

  @type contract_name ::
          :error
          | :tool_proposal
          | :job_create_request
          | :job_create_response
          | :job_response
          | :ai_job_execute_request
          | :ai_job_accepted
          | :ai_job_completion
          | :ai_job_completion_ack

  @spec names() :: [contract_name()]
  def names do
    @schemas
    |> Map.keys()
    |> Enum.sort()
  end

  @spec validate(
          contract_name(),
          map()
        ) ::
          :ok
          | {:error, term()}
  def validate(
        contract_name,
        payload
      )
      when is_atom(contract_name) and
             is_map(payload) do
    with {:ok, schema} <-
           fetch_schema(contract_name),
         {:ok, compiled} <-
           JSONSchex.compile(schema) do
      JSONSchex.validate(
        compiled,
        payload
      )
    end
  end

  def validate(
        contract_name,
        payload
      ) do
    {:error,
     {
       :invalid_contract_validation_request,
       contract_name,
       payload
     }}
  end

  @spec valid?(
          contract_name(),
          map()
        ) :: boolean()
  def valid?(
        contract_name,
        payload
      ) do
    validate(
      contract_name,
      payload
    ) == :ok
  end

  @spec fetch_schema(contract_name()) ::
          {:ok, map()}
          | {:error, {:unknown_contract, term()}}
  def fetch_schema(contract_name) do
    case Map.fetch(
           @schemas,
           contract_name
         ) do
      {:ok, schema} ->
        {:ok, schema}

      :error ->
        {:error,
         {
           :unknown_contract,
           contract_name
         }}
    end
  end
end
