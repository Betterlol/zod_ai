///|
/// A high-risk refund never reaches its execution function before approval.
fn main {
  let refund = @zod_ai.tool_with_policy(
    "refund_order",
    "Refund an order after human approval.",
    @moon_zod.object({ "order_id": @moon_zod.string().min(1) }).strict(),
    @moon_zod.object({ "status": @moon_zod.string() }).strict(),
    @zod_ai.require_approval(),
    _input => Ok(Json::object({ "status": Json::string("refunded") })),
  )
  let output = @moon_zod.object({ "status": @moon_zod.string() }).strict()
  let model = @zod_ai.mock_model([
    @zod_ai.tool_response(
      @zod_ai.tool_call(
        "refund-1",
        "refund_order",
        Json::object({ "order_id": Json::string("ord-7") }),
      ),
    ),
  ])
  match @zod_ai.agent([refund], output).run(model, "Refund order ord-7") {
    Err(ApprovalRequired(request)) =>
      println(
        "Approval required for " +
        request.call.name +
        ": " +
        request.validated_arguments.stringify(),
      )
    _ => println("Unexpected result")
  }
}
