/// A schema-first, deterministic Agent runtime for MoonBit.
///
/// The MVP deliberately keeps the model transport out of the core. Callers
/// supply a `Model` function, which makes an Agent run testable with fixed
/// responses and lets provider adapters be added without changing contracts.

///|
pub struct ToolCall {
  id : String
  name : String
  arguments : Json
}

///|
pub fn tool_call(id : String, name : String, arguments : Json) -> ToolCall {
  { id, name, arguments, }
}

///|
pub struct ToolResult {
  call_id : String
  tool_name : String
  value : Json
}

///|
/// Per-run data supplied to context-aware tools.
///
/// Dependencies deliberately use `Json` at the runtime boundary. This keeps a
/// `ToolContract` reusable across MoonBit targets while callers may still
/// validate their dependency object with moon_zod before supplying it.
pub struct RunContext {
  deps : Json
  prompt : String
  messages : Array[Message]
  tool_call_id : String
  turn : Int32
}

///|
pub fn run_context(
  deps : Json,
  prompt : String,
  messages : Array[Message],
  tool_call_id : String,
  turn : Int32,
) -> RunContext {
  { deps, prompt, messages, tool_call_id, turn, }
}

///|
pub struct RetryPrompt {
  call_id : String
  tool_name : String
  reason : String
}

///|
pub enum Message {
  UserPrompt(String)
  ToolCallRequested(ToolCall)
  ToolReturned(ToolResult)
  RetryRequested(RetryPrompt)
}

///|
pub struct ToolDefinition {
  name : String
  description : String
  input_json_schema : Json
}

///|
pub enum ModelResponse {
  ToolCall(ToolCall)
  FinalOutput(Json)
}

///|
pub fn tool_response(call : ToolCall) -> ModelResponse {
  ToolCall(call)
}

///|
pub fn final_output(value : Json) -> ModelResponse {
  FinalOutput(value)
}

///|
pub type Model = (Array[Message], Array[ToolDefinition]) -> Result[
  ModelResponse,
  String,
]

///|
/// Create a deterministic model from a finite response sequence.
///
/// It is intended for tests and examples. Exhausting the sequence produces a
/// model error, which makes an unexpected extra Agent turn visible to a test.
pub fn mock_model(responses : Array[ModelResponse]) -> Model {
  let mut next = 0
  fn(_messages, _definitions) {
    if next >= responses.length() {
      Err("Mock model response sequence exhausted")
    } else {
      let response = responses[next]
      next = next + 1
      Ok(response)
    }
  }
}

///|
pub struct ToolContract {
  name : String
  description : String
  input_schema : @moon_zod.Schema
  output_schema : @moon_zod.Schema
  execution_policy : ExecutionPolicy
  execute : (RunContext, Json) -> Result[Json, String]
}

///|
pub enum ExecutionPolicy {
  Allow
  Reject(String)
  RequireApproval
}

///|
pub fn reject(reason : String) -> ExecutionPolicy {
  Reject(reason)
}

///|
pub fn require_approval() -> ExecutionPolicy {
  RequireApproval
}

///|
pub fn tool(
  name : String,
  description : String,
  input_schema : @moon_zod.Schema,
  output_schema : @moon_zod.Schema,
  execute : (Json) -> Result[Json, String],
) -> ToolContract {
  tool_with_context_and_policy(
    name,
    description,
    input_schema,
    output_schema,
    Allow,
    fn(_context, input) { execute(input) },
  )
}

///|
pub fn tool_with_policy(
  name : String,
  description : String,
  input_schema : @moon_zod.Schema,
  output_schema : @moon_zod.Schema,
  execution_policy : ExecutionPolicy,
  execute : (Json) -> Result[Json, String],
) -> ToolContract {
  tool_with_context_and_policy(
    name,
    description,
    input_schema,
    output_schema,
    execution_policy,
    fn(_context, input) { execute(input) },
  )
}

///|
/// Create a tool that can access run-scoped dependencies and transcript data.
pub fn tool_with_context(
  name : String,
  description : String,
  input_schema : @moon_zod.Schema,
  output_schema : @moon_zod.Schema,
  execute : (RunContext, Json) -> Result[Json, String],
) -> ToolContract {
  tool_with_context_and_policy(
    name,
    description,
    input_schema,
    output_schema,
    Allow,
    execute,
  )
}

///|
pub fn tool_with_context_and_policy(
  name : String,
  description : String,
  input_schema : @moon_zod.Schema,
  output_schema : @moon_zod.Schema,
  execution_policy : ExecutionPolicy,
  execute : (RunContext, Json) -> Result[Json, String],
) -> ToolContract {
  { name, description, input_schema, output_schema, execution_policy, execute, }
}

///|
/// A reusable, composable group of tools.
pub struct ToolSet {
  tools : Array[ToolContract]
}

///|
pub fn tool_set(tools : Array[ToolContract]) -> ToolSet {
  { tools, }
}

///|
pub fn ToolSet::definitions(self : ToolSet) -> Array[ToolDefinition] {
  self.tools.map(item => item.definition())
}

///|
/// Merge tool sets while rejecting duplicate names before a model can see an
/// ambiguous contract.
pub fn combine_tool_sets(tool_sets : Array[ToolSet]) -> Result[ToolSet, String] {
  let merged : Array[ToolContract] = []
  for tool_set in tool_sets {
    for tool in tool_set.tools {
      for existing in merged {
        if existing.name == tool.name {
          return Err("Duplicate tool name: " + tool.name)
        }
      }
      merged.push(tool)
    }
  }
  Ok({ tools: merged, })
}

///|
pub struct RepairPolicy {
  max_turns : Int32
  max_tool_retries : Int32
  max_output_retries : Int32
  retry_tool_failures : Bool
}

///|
pub fn RepairPolicy::default() -> RepairPolicy {
  {
    max_turns: 12,
    max_tool_retries: 2,
    max_output_retries: 2,
    retry_tool_failures: false,
  }
}

///|
pub fn repair_policy(
  max_turns : Int32,
  max_tool_retries : Int32,
  max_output_retries : Int32,
  retry_tool_failures~ : Bool = false,
) -> RepairPolicy {
  { max_turns, max_tool_retries, max_output_retries, retry_tool_failures, }
}

///|
pub struct Agent {
  tools : Array[ToolContract]
  output_schema : @moon_zod.Schema
  repair_policy : RepairPolicy
}

///|
pub fn agent(
  tools : Array[ToolContract],
  output_schema : @moon_zod.Schema,
  repair_policy~ : RepairPolicy = RepairPolicy::default(),
) -> Agent {
  { tools, output_schema, repair_policy, }
}

///|
pub fn agent_with_tool_sets(
  tool_sets : Array[ToolSet],
  output_schema : @moon_zod.Schema,
  repair_policy~ : RepairPolicy = RepairPolicy::default(),
) -> Result[Agent, String] {
  match combine_tool_sets(tool_sets) {
    Ok(merged) => Ok(agent(merged.tools, output_schema, repair_policy~))
    Err(reason) => Err(reason)
  }
}

///|
pub enum AgentEvent {
  ModelRequested(Int32)
  ToolCallReceived(String, String)
  ToolInputRejected(String, Array[String])
  ToolStarted(String, String)
  ToolCompleted(String, String)
  ApprovalRequested(String, String)
  FinalOutputRejected(Array[String])
  RepairRequested(String)
  Completed
}

///|
pub struct ApprovalRequest {
  call : ToolCall
  validated_arguments : Json
  prompt : String
  deps : Json
  messages : Array[Message]
  events : Array[AgentEvent]
  responses : Array[ModelResponse]
  turns : Int32
  tool_retries : Int32
  output_retries : Int32
}

///|
pub enum AgentFailure {
  ModelFailed(String)
  ToolOutputInvalid(String, Array[@moon_zod.ValidationError])
  ToolExecutionFailed(String, String)
  ToolRejected(String, String)
  ApprovalRequired(ApprovalRequest)
  RetryLimitExceeded(String)
  TurnLimitExceeded(Int32)
}

///|
pub struct AgentRunResult {
  output : Json
  messages : Array[Message]
  events : Array[AgentEvent]
  responses : Array[ModelResponse]
}

///|
/// Recreate a deterministic model from a completed run's recorded model
/// responses. It is useful for regression and contract tests without a live
/// provider.
pub fn replay_model(result : AgentRunResult) -> Model {
  mock_model(result.responses)
}

///|
/// A transport-independent MCP tool description derived from the same schema
/// contract offered to language models.
pub struct McpToolDefinition {
  name : String
  description : String
  input_schema : Json
}

///|
/// Serialize a tool description using the MCP `tools/list` field names.
pub fn McpToolDefinition::to_json(self : McpToolDefinition) -> Json {
  Json::object({
    "name": Json::string(self.name),
    "description": Json::string(self.description),
    "inputSchema": self.input_schema,
  })
}

///|
pub fn ToolContract::mcp_definition(self : ToolContract) -> McpToolDefinition {
  {
    name: self.name,
    description: self.description,
    input_schema: @moon_zod.to_json_schema(self.input_schema),
  }
}

///|
pub fn Agent::mcp_tool_definitions(self : Agent) -> Array[McpToolDefinition] {
  self.tools.map(item => item.mcp_definition())
}

///|
/// Adapt an MCP client's `tools/call` operation into a local ToolContract.
/// The caller owns connection management and transport; the agent still
/// validates both arguments and returned values through moon_zod.
pub fn mcp_tool(
  name : String,
  description : String,
  input_schema : @moon_zod.Schema,
  output_schema : @moon_zod.Schema,
  call : (String, Json) -> Result[Json, String],
) -> ToolContract {
  tool_with_context(name, description, input_schema, output_schema, fn(
    _context,
    arguments,
  ) {
    call(name, arguments)
  })
}

///|
pub fn ToolContract::definition(self : ToolContract) -> ToolDefinition {
  {
    name: self.name,
    description: self.description,
    input_json_schema: @moon_zod.to_json_schema(self.input_schema),
  }
}

///|
pub fn Agent::tool_definitions(self : Agent) -> Array[ToolDefinition] {
  let definitions : Array[ToolDefinition] = []
  for item in self.tools {
    definitions.push(item.definition())
  }
  definitions
}

///|
fn Agent::find_tool(self : Agent, name : String) -> ToolContract? {
  for item in self.tools {
    if item.name == name {
      return Some(item)
    }
  }
  None
}

///|
fn format_validation_errors(
  errors : Array[@moon_zod.ValidationError],
) -> Array[String] {
  let lines : Array[String] = []
  for error in errors {
    lines.push(error.to_string())
  }
  lines
}

///|
fn tool_retry_reason(
  tool_name : String,
  errors : Array[@moon_zod.ValidationError],
) -> String {
  "Tool `" +
  tool_name +
  "` arguments are invalid:\n" +
  format_validation_errors(errors).join("\n") +
  "\nFix every error and call the tool again."
}

///|
fn output_retry_reason(errors : Array[@moon_zod.ValidationError]) -> String {
  "The final output is invalid:\n" +
  format_validation_errors(errors).join("\n") +
  "\nReturn a valid final output."
}

///|
fn missing_tool_retry_reason(tool_name : String) -> String {
  "Tool `" +
  tool_name +
  "` is not available. Choose one of the advertised tools."
}

///|
fn execution_retry_reason(tool_name : String, reason : String) -> String {
  "Tool `" +
  tool_name +
  "` failed: " +
  reason +
  "\nCorrect the arguments or choose another tool."
}

///|
fn add_tool_retry(
  messages : Array[Message],
  events : Array[AgentEvent],
  call : ToolCall,
  reason : String,
) -> Unit {
  messages.push(
    RetryRequested({ call_id: call.id, tool_name: call.name, reason, }),
  )
  events.push(RepairRequested(reason))
}

///|
/// Run a complete model → tool → model loop.
///
/// Invalid tool arguments consume only the tool retry budget. Invalid final
/// output consumes only the output retry budget. Tool return values are
/// application data, so an invalid return terminates the run instead of asking
/// the model to repair data it did not produce.
pub fn Agent::run(
  self : Agent,
  model : Model,
  prompt : String,
) -> Result[AgentRunResult, AgentFailure] {
  self.run_with_deps(model, prompt, Json::null())
}

///|
/// Run an agent with JSON dependencies exposed to context-aware tools.
pub fn Agent::run_with_deps(
  self : Agent,
  model : Model,
  prompt : String,
  deps : Json,
) -> Result[AgentRunResult, AgentFailure] {
  self.continue_run(model, prompt, deps, [UserPrompt(prompt)], [], [], 0, 0, 0)
}

///|
/// Continue a run that paused at an explicit approval boundary.
///
/// Passing `approved=false` records no side effect and returns the same policy
/// failure shape as a rejected tool.
pub fn Agent::resume_after_approval(
  self : Agent,
  model : Model,
  request : ApprovalRequest,
  approved : Bool,
) -> Result[AgentRunResult, AgentFailure] {
  let contract = match self.find_tool(request.call.name) {
    Some(contract) => contract
    None =>
      return Err(ToolRejected(request.call.name, "Tool is no longer available"))
  }
  if !approved {
    return Err(ToolRejected(contract.name, "Approval was denied"))
  }
  match contract.execution_policy {
    RequireApproval => ()
    Reject(reason) => return Err(ToolRejected(contract.name, reason))
    Allow =>
      return Err(ToolRejected(contract.name, "Tool does not require approval"))
  }
  let context = run_context(
    request.deps,
    request.prompt,
    request.messages,
    request.call.id,
    request.turns,
  )
  request.events.push(ToolStarted(contract.name, request.call.id))
  let raw_output = match
    (contract.execute)(context, request.validated_arguments) {
    Ok(output) => output
    Err(reason) => {
      if !self.repair_policy.retry_tool_failures {
        return Err(ToolExecutionFailed(contract.name, reason))
      }
      let next_tool_retries = request.tool_retries + 1
      if next_tool_retries > self.repair_policy.max_tool_retries {
        return Err(RetryLimitExceeded("tool"))
      }
      add_tool_retry(
        request.messages,
        request.events,
        request.call,
        execution_retry_reason(contract.name, reason),
      )
      return self.continue_run(
        model,
        request.prompt,
        request.deps,
        request.messages,
        request.events,
        request.responses,
        request.turns,
        next_tool_retries,
        request.output_retries,
      )
    }
  }
  let clean_output = match contract.output_schema.parse(raw_output) {
    Ok(output) => output
    Err(errors) => return Err(ToolOutputInvalid(contract.name, errors))
  }
  request.messages.push(
    ToolReturned({
      call_id: request.call.id,
      tool_name: contract.name,
      value: clean_output,
    }),
  )
  request.events.push(ToolCompleted(contract.name, request.call.id))
  self.continue_run(
    model,
    request.prompt,
    request.deps,
    request.messages,
    request.events,
    request.responses,
    request.turns,
    request.tool_retries,
    request.output_retries,
  )
}

///|
fn Agent::continue_run(
  self : Agent,
  model : Model,
  prompt : String,
  deps : Json,
  messages : Array[Message],
  events : Array[AgentEvent],
  responses : Array[ModelResponse],
  initial_turns : Int32,
  initial_tool_retries : Int32,
  initial_output_retries : Int32,
) -> Result[AgentRunResult, AgentFailure] {
  let definitions = self.tool_definitions()
  let mut turns = initial_turns
  let mut tool_retries = initial_tool_retries
  let mut output_retries = initial_output_retries

  while turns < self.repair_policy.max_turns {
    turns = turns + 1
    events.push(ModelRequested(turns))
    let response = match model(messages, definitions) {
      Ok(response) => response
      Err(reason) => return Err(ModelFailed(reason))
    }
    responses.push(response)
    match response {
      ToolCall(call) => {
        messages.push(ToolCallRequested(call))
        events.push(ToolCallReceived(call.name, call.id))
        match self.find_tool(call.name) {
          None => {
            tool_retries = tool_retries + 1
            if tool_retries > self.repair_policy.max_tool_retries {
              return Err(RetryLimitExceeded("tool"))
            }
            add_tool_retry(
              messages,
              events,
              call,
              missing_tool_retry_reason(call.name),
            )
          }
          Some(contract) =>
            match contract.input_schema.parse(call.arguments) {
              Err(errors) => {
                tool_retries = tool_retries + 1
                if tool_retries > self.repair_policy.max_tool_retries {
                  return Err(RetryLimitExceeded("tool"))
                }
                events.push(
                  ToolInputRejected(call.name, format_validation_errors(errors)),
                )
                add_tool_retry(
                  messages,
                  events,
                  call,
                  tool_retry_reason(contract.name, errors),
                )
              }
              Ok(clean_input) =>
                match contract.execution_policy {
                  Reject(reason) =>
                    return Err(ToolRejected(contract.name, reason))
                  RequireApproval => {
                    events.push(ApprovalRequested(call.name, call.id))
                    return Err(
                      ApprovalRequired({
                        call,
                        validated_arguments: clean_input,
                        prompt,
                        deps,
                        messages,
                        events,
                        responses,
                        turns,
                        tool_retries,
                        output_retries,
                      }),
                    )
                  }
                  Allow => {
                    events.push(ToolStarted(call.name, call.id))
                    let context = run_context(
                      deps,
                      prompt,
                      messages,
                      call.id,
                      turns,
                    )
                    match (contract.execute)(context, clean_input) {
                      Err(reason) => {
                        if !self.repair_policy.retry_tool_failures {
                          return Err(ToolExecutionFailed(contract.name, reason))
                        }
                        tool_retries = tool_retries + 1
                        if tool_retries > self.repair_policy.max_tool_retries {
                          return Err(RetryLimitExceeded("tool"))
                        }
                        add_tool_retry(
                          messages,
                          events,
                          call,
                          execution_retry_reason(contract.name, reason),
                        )
                      }
                      Ok(raw_output) =>
                        match contract.output_schema.parse(raw_output) {
                          Err(errors) =>
                            return Err(ToolOutputInvalid(contract.name, errors))
                          Ok(clean_output) => {
                            messages.push(
                              ToolReturned({
                                call_id: call.id,
                                tool_name: call.name,
                                value: clean_output,
                              }),
                            )
                            events.push(ToolCompleted(call.name, call.id))
                          }
                        }
                    }
                  }
                }
            }
        }
      }
      FinalOutput(raw_output) =>
        match self.output_schema.parse(raw_output) {
          Ok(output) => {
            events.push(Completed)
            return Ok({ output, messages, events, responses, })
          }
          Err(errors) => {
            output_retries = output_retries + 1
            if output_retries > self.repair_policy.max_output_retries {
              return Err(RetryLimitExceeded("output"))
            }
            let lines = format_validation_errors(errors)
            events.push(FinalOutputRejected(lines))
            let reason = output_retry_reason(errors)
            messages.push(
              RetryRequested({ call_id: "", tool_name: "", reason, }),
            )
            events.push(RepairRequested(reason))
          }
        }
    }
  }
  Err(TurnLimitExceeded(self.repair_policy.max_turns))
}
