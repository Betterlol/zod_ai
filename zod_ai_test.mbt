///|
fn lookup_input_schema() -> @moon_zod.Schema {
  @moon_zod.object({ "order_id": @moon_zod.string().min(1) }).strict()
}

///|
fn lookup_output_schema() -> @moon_zod.Schema {
  @moon_zod.object({ "status": @moon_zod.enum_values(["paid", "cancelled"]) }).strict()
}

///|
fn action_output_schema() -> @moon_zod.Schema {
  @moon_zod.object({
    "action": @moon_zod.enum_values(["looked_up", "cancelled"]),
    "status": @moon_zod.string(),
  }).strict()
}

///|
fn lookup_order(_input : Json) -> Result[Json, String] {
  Ok(Json::object({ "status": Json::string("paid") }))
}

///|
fn invalid_lookup_output(_input : Json) -> Result[Json, String] {
  Ok(Json::object({ "status": Json::number(42.0) }))
}

///|
fn order_tool(execute : (Json) -> Result[Json, String]) -> @zod_ai.ToolContract {
  @zod_ai.tool(
    "lookup_order",
    "Look up an order by its identifier.",
    lookup_input_schema(),
    lookup_output_schema(),
    execute,
  )
}

///|
fn repair_model(
  messages : Array[@zod_ai.Message],
  _definitions : Array[@zod_ai.ToolDefinition],
) -> Result[@zod_ai.ModelResponse, String] {
  if messages.length() == 1 {
    return Ok(
      @zod_ai.tool_response(
        @zod_ai.tool_call(
          "call-1",
          "lookup_order",
          Json::object({ "order_id": Json::number(7.0) }),
        ),
      ),
    )
  }
  if messages.length() == 3 {
    return Ok(
      @zod_ai.tool_response(
        @zod_ai.tool_call(
          "call-2",
          "lookup_order",
          Json::object({ "order_id": Json::string("ord-7") }),
        ),
      ),
    )
  }
  Ok(
    @zod_ai.final_output(
      Json::object({
        "action": Json::string("looked_up"),
        "status": Json::string("paid"),
      }),
    ),
  )
}

///|
fn one_tool_call_model(
  _messages : Array[@zod_ai.Message],
  _definitions : Array[@zod_ai.ToolDefinition],
) -> Result[@zod_ai.ModelResponse, String] {
  Ok(
    @zod_ai.tool_response(
      @zod_ai.tool_call(
        "call-1",
        "lookup_order",
        Json::object({ "order_id": Json::string("ord-7") }),
      ),
    ),
  )
}

///|
fn always_invalid_tool_model(
  _messages : Array[@zod_ai.Message],
  _definitions : Array[@zod_ai.ToolDefinition],
) -> Result[@zod_ai.ModelResponse, String] {
  Ok(
    @zod_ai.tool_response(
      @zod_ai.tool_call(
        "call-invalid",
        "lookup_order",
        Json::object({ "order_id": Json::number(7.0) }),
      ),
    ),
  )
}

///|
fn refund_tool_call_model(
  _messages : Array[@zod_ai.Message],
  _definitions : Array[@zod_ai.ToolDefinition],
) -> Result[@zod_ai.ModelResponse, String] {
  Ok(
    @zod_ai.tool_response(
      @zod_ai.tool_call(
        "refund-1",
        "refund_order",
        Json::object({ "order_id": Json::string("ord-7") }),
      ),
    ),
  )
}

///|
test "agent repairs invalid tool arguments before execution" {
  let agent = @zod_ai.agent([order_tool(lookup_order)], action_output_schema())
  guard agent.run(repair_model, "Where is order ord-7?") is Ok(result) else {
    fail("expected a completed run")
  }
  assert_eq(
    result.output,
    Json::object({
      "action": Json::string("looked_up"),
      "status": Json::string("paid"),
    }),
  )
  assert_eq(result.messages.length(), 5)
  assert_eq(result.events.length(), 10)
}

///|
test "agent retries invalid final output with a separate output budget" {
  let agent = @zod_ai.agent([], action_output_schema())
  let model = @zod_ai.mock_model([
    @zod_ai.final_output(
      Json::object({
        "action": Json::string("unknown"),
        "status": Json::number(7.0),
      }),
    ),
    @zod_ai.final_output(
      Json::object({
        "action": Json::string("looked_up"),
        "status": Json::string("paid"),
      }),
    ),
  ])
  guard agent.run(model, "Look up the order") is Ok(result) else {
    fail("expected a completed run")
  }
  assert_eq(result.messages.length(), 2)
  assert_eq(result.events.length(), 5)
}

///|
test "tool retries stop at the configured limit" {
  let policy = @zod_ai.repair_policy(4, 1, 1)
  let agent = @zod_ai.agent(
    [order_tool(lookup_order)],
    action_output_schema(),
    repair_policy=policy,
  )
  guard agent.run(always_invalid_tool_model, "Where is order ord-7?")
    is Err(RetryLimitExceeded(scope)) else {
    fail("expected tool retry limit failure")
  }
  assert_eq(scope, "tool")
}

///|
test "approval policy returns before a high risk tool executes" {
  let refund = @zod_ai.tool_with_policy(
    "refund_order",
    "Refund an order.",
    lookup_input_schema(),
    lookup_output_schema(),
    @zod_ai.require_approval(),
    invalid_lookup_output,
  )
  let agent = @zod_ai.agent([refund], action_output_schema())
  guard agent.run(refund_tool_call_model, "Refund order ord-7")
    is Err(ApprovalRequired(request)) else {
    fail("expected an approval request")
  }
  assert_eq(request.call.name, "refund_order")
}

///|
test "an approved tool call resumes the original run" {
  let refund = @zod_ai.tool_with_policy(
    "refund_order",
    "Refund an order.",
    lookup_input_schema(),
    lookup_output_schema(),
    @zod_ai.require_approval(),
    lookup_order,
  )
  let agent = @zod_ai.agent([refund], action_output_schema())
  let initial = @zod_ai.mock_model([
    @zod_ai.tool_response(
      @zod_ai.tool_call(
        "refund-1",
        "refund_order",
        Json::object({ "order_id": Json::string("ord-7") }),
      ),
    ),
  ])
  guard agent.run(initial, "Refund order ord-7")
    is Err(ApprovalRequired(request)) else {
    fail("expected approval boundary")
  }
  let resumed_model = @zod_ai.mock_model([
    @zod_ai.final_output(
      Json::object({
        "action": Json::string("cancelled"),
        "status": Json::string("paid"),
      }),
    ),
  ])
  guard agent.resume_after_approval(resumed_model, request, true) is Ok(result) else {
    fail("expected a completed resumed run")
  }
  assert_eq(
    result.output,
    Json::object({
      "action": Json::string("cancelled"),
      "status": Json::string("paid"),
    }),
  )
  assert_eq(result.messages.length(), 3)
  assert_eq(result.events.length(), 7)
}

///|
test "invalid tool return data terminates the run" {
  let agent = @zod_ai.agent(
    [order_tool(invalid_lookup_output)],
    action_output_schema(),
  )
  guard agent.run(one_tool_call_model, "Where is order ord-7?")
    is Err(ToolOutputInvalid(name, errors)) else {
    fail("expected a tool output validation failure")
  }
  assert_eq(name, "lookup_order")
  assert_eq(errors.length(), 1)
}

///|
test "tool definitions export moon_zod JSON Schema" {
  let agent = @zod_ai.agent([order_tool(lookup_order)], action_output_schema())
  let definitions = agent.tool_definitions()
  assert_eq(definitions.length(), 1)
  assert_eq(definitions[0].name, "lookup_order")
  assert_eq(
    definitions[0].input_json_schema,
    @moon_zod.to_json_schema(lookup_input_schema()),
  )
}

///|
test "context-aware tools receive run dependencies" {
  let mut received_deps = Json::null()
  let contextual_tool = @zod_ai.tool_with_context(
    "lookup_order",
    "Look up an order with a dependency-backed service.",
    lookup_input_schema(),
    lookup_output_schema(),
    fn(context, _input) {
      received_deps = context.deps
      Ok(Json::object({ "status": Json::string("paid") }))
    },
  )
  let agent = @zod_ai.agent([contextual_tool], action_output_schema())
  let model = @zod_ai.mock_model([
    @zod_ai.tool_response(
      @zod_ai.tool_call(
        "context-1",
        "lookup_order",
        Json::object({ "order_id": Json::string("ord-7") }),
      ),
    ),
    @zod_ai.final_output(
      Json::object({
        "action": Json::string("looked_up"),
        "status": Json::string("paid"),
      }),
    ),
  ])
  guard agent.run_with_deps(
      model,
      "Where is order ord-7?",
      Json::object({ "tenant": Json::string("acme") }),
    )
    is Ok(_) else {
    fail("expected a completed run")
  }
  assert_eq(received_deps, Json::object({ "tenant": Json::string("acme") }))
}

///|
test "tool sets compose and reject ambiguous names" {
  guard @zod_ai.combine_tool_sets([
      @zod_ai.tool_set([order_tool(lookup_order)]),
      @zod_ai.tool_set([]),
    ])
    is Ok(merged) else {
    fail("expected compatible tool sets to merge")
  }
  assert_eq(merged.definitions().length(), 1)
  guard @zod_ai.combine_tool_sets([
      @zod_ai.tool_set([order_tool(lookup_order)]),
      @zod_ai.tool_set([order_tool(lookup_order)]),
    ])
    is Err(reason) else {
    fail("expected duplicate tool name failure")
  }
  assert_eq(reason, "Duplicate tool name: lookup_order")
}

///|
test "completed runs can be replayed by a deterministic model" {
  let agent = @zod_ai.agent([], action_output_schema())
  let original = @zod_ai.mock_model([
    @zod_ai.final_output(
      Json::object({
        "action": Json::string("looked_up"),
        "status": Json::string("paid"),
      }),
    ),
  ])
  guard agent.run(original, "Look up the order") is Ok(first) else {
    fail("expected original run")
  }
  guard agent.run(@zod_ai.replay_model(first), "Look up the order")
    is Ok(replayed) else {
    fail("expected replayed run")
  }
  assert_eq(replayed.output, first.output)
  assert_eq(replayed.responses.length(), 1)
}

///|
test "MCP contracts export and validate through the same tool contract" {
  let mut received_name = ""
  let remote_tool = @zod_ai.mcp_tool(
    "lookup_order",
    "Look up an order through MCP.",
    lookup_input_schema(),
    lookup_output_schema(),
    fn(name, _arguments) {
      received_name = name
      Ok(Json::object({ "status": Json::string("paid") }))
    },
  )
  let mcp = remote_tool.mcp_definition()
  assert_eq(mcp.name, "lookup_order")
  assert_eq(mcp.input_schema, @moon_zod.to_json_schema(lookup_input_schema()))
  assert_eq(
    mcp.to_json(),
    Json::object({
      "name": Json::string("lookup_order"),
      "description": Json::string("Look up an order through MCP."),
      "inputSchema": @moon_zod.to_json_schema(lookup_input_schema()),
    }),
  )
  let agent = @zod_ai.agent([remote_tool], action_output_schema())
  let model = @zod_ai.mock_model([
    @zod_ai.tool_response(
      @zod_ai.tool_call(
        "mcp-1",
        "lookup_order",
        Json::object({ "order_id": Json::string("ord-7") }),
      ),
    ),
    @zod_ai.final_output(
      Json::object({
        "action": Json::string("looked_up"),
        "status": Json::string("paid"),
      }),
    ),
  ])
  guard agent.run(model, "Where is order ord-7?") is Ok(_) else {
    fail("expected a completed MCP-backed run")
  }
  assert_eq(received_name, "lookup_order")
}
