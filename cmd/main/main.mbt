///|
/// A runnable MVP showcase: the mock model first sends invalid tool arguments,
/// receives moon_zod's field-level repair prompt, then completes an order lookup.
/// Run with `moon run cmd/main` from the project root.
fn main {
  let lookup = @zod_ai.tool(
    "lookup_order",
    "Look up an order by its identifier.",
    @moon_zod.object({ "order_id": @moon_zod.string().min(1) }).strict(),
    @moon_zod.object({ "status": @moon_zod.enum_values(["paid", "cancelled"]) }).strict(),
    lookup_order,
  )
  let result_schema = @moon_zod.object({
    "action": @moon_zod.enum_values(["looked_up", "cancelled"]),
    "status": @moon_zod.string(),
  }).strict()
  let agent = @zod_ai.agent([lookup], result_schema)

  match agent.run(order_model, "Where is order ord-7?") {
    Ok(result) => {
      println(
        "Agent completed after \{result.events.length().to_string()} events.",
      )
      println(result.output.stringify(indent=2))
    }
    Err(_) => println("Agent failed before producing a valid result.")
  }
}

///|
fn lookup_order(_input : Json) -> Result[Json, String] {
  Ok(Json::object({ "status": Json::string("paid") }))
}

///|
fn order_model(
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
