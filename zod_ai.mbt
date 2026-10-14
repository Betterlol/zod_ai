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
  execute : (Json) -> Result[Json, String]
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
  tool_with_policy(
    name,
    description,
    input_schema,
    output_schema,
    Allow,
    execute,
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
  { name, description, input_schema, output_schema, execution_policy, execute, }
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
  let messages : Array[Message] = [UserPrompt(prompt)]
  let events : Array[AgentEvent] = []
  let definitions = self.tool_definitions()
  let mut turns = 0
  let mut tool_retries = 0
  let mut output_retries = 0

  while turns < self.repair_policy.max_turns {
    turns = turns + 1
    events.push(ModelRequested(turns))
    let response = match model(messages, definitions) {
      Ok(response) => response
      Err(reason) => return Err(ModelFailed(reason))
    }
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
                      }),
                    )
                  }
                  Allow => {
                    events.push(ToolStarted(call.name, call.id))
                    match (contract.execute)(clean_input) {
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
            return Ok({ output, messages, events, })
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
