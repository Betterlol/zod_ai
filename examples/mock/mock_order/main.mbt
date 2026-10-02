///|
/// A complete mock order lookup with an invalid first tool call and repair.
fn main {
  let lookup = @zod_ai.tool(
    "lookup_order",
    "Look up an order by its identifier.",
    @moon_zod.object({ "order_id": @moon_zod.string().min(1) }).strict(),
    @moon_zod.object({ "status": @moon_zod.string() }).strict(),
    _input => Ok(Json::object({ "status": Json::string("paid") })),
  )
  let output = @moon_zod.object({
    "action": @moon_zod.enum_values(["looked_up"]),
    "status": @moon_zod.string(),
  }).strict()
  let model = @zod_ai.mock_model([
    @zod_ai.tool_response(
      @zod_ai.tool_call(
        "call-1",
        "lookup_order",
        Json::object({ "order_id": Json::number(7.0) }),
      ),
    ),
    @zod_ai.tool_response(
      @zod_ai.tool_call(
        "call-2",
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
  match @zod_ai.agent([lookup], output).run(model, "Where is order ord-7?") {
    Ok(result) => println(result.output.stringify(indent=2))
    Err(_) => println("Agent failed")
  }
}
