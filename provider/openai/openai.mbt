/// OpenAI-compatible Chat Completions JSON protocol mapping for zod_ai.
/// This package owns no HTTP client; a WASI HTTP, native, or browser transport
/// submits `request()` and passes its decoded JSON response to `response()`.

///|
fn tools(definitions : Array[@zod_ai.ToolDefinition]) -> Array[Json] {
  definitions.map(definition => {
    Json::object({
      "type": Json::string("function"),
      "function": Json::object({
        "name": Json::string(definition.name),
        "description": Json::string(definition.description),
        "parameters": definition.input_json_schema,
        "strict": Json::boolean(true),
      }),
    })
  })
}

///|
fn messages(history : Array[@zod_ai.Message]) -> Array[Json] {
  let result : Array[Json] = []
  for message in history {
    match message {
      UserPrompt(content) =>
        result.push(Json::object({ "role": "user", "content": content }))
      ToolCallRequested(call) =>
        result.push(
          Json::object({
            "role": "assistant",
            "tool_calls": Json::array([
              Json::object({
                "id": call.id,
                "type": "function",
                "function": Json::object({
                  "name": call.name,
                  "arguments": call.arguments.stringify(),
                }),
              }),
            ]),
          }),
        )
      ToolReturned(value) =>
        result.push(
          Json::object({
            "role": "tool",
            "tool_call_id": value.call_id,
            "content": value.value.stringify(),
          }),
        )
      RetryRequested(retry) =>
        result.push(Json::object({ "role": "user", "content": retry.reason }))
    }
  }
  result
}

///|
pub fn request(
  model : String,
  history : Array[@zod_ai.Message],
  definitions : Array[@zod_ai.ToolDefinition],
) -> Json {
  Json::object({
    "model": model,
    "messages": Json::array(messages(history)),
    "tools": Json::array(tools(definitions)),
  })
}

///|
pub fn response(body : Json) -> Result[@zod_ai.ModelResponse, String] {
  guard body is Object(root) else {
    return Err("OpenAI response must be an object")
  }
  guard root.get("choices") is Some(Array(choices)) && choices.length() > 0 else {
    return Err("OpenAI response has no choices")
  }
  guard choices[0] is Object(choice) &&
    choice.get("message") is Some(Object(message)) else {
    return Err("OpenAI response choice has no message")
  }
  match message.get("tool_calls") {
    Some(Array(calls)) if calls.length() > 0 => decode_tool_call(calls[0])
    _ =>
      match message.get("content") {
        Some(String(content)) =>
          Ok(
            @zod_ai.final_output(
              @json.parse(content) catch {
                _ => Json::string(content)
              },
            ),
          )
        _ => Err("OpenAI response has neither tool_calls nor text content")
      }
  }
}

///|
fn decode_tool_call(value : Json) -> Result[@zod_ai.ModelResponse, String] {
  guard value is Object(call) else {
    return Err("OpenAI tool call must be an object")
  }
  guard call.get("id") is Some(String(id)) else {
    return Err("OpenAI tool call has no id")
  }
  guard call.get("function") is Some(Object(function)) else {
    return Err("OpenAI tool call has no function")
  }
  guard function.get("name") is Some(String(name)) else {
    return Err("OpenAI tool call has no function name")
  }
  guard function.get("arguments") is Some(String(text)) else {
    return Err("OpenAI tool call has no arguments")
  }
  let arguments = @json.parse(text) catch {
    _ => return Err("OpenAI tool arguments are not JSON")
  }
  Ok(@zod_ai.tool_response(@zod_ai.tool_call(id, name, arguments)))
}
