///|
test "response decodes a JSON final output" {
  let body = Json::object({
    "choices": Json::array([
      Json::object({
        "message": Json::object({
          "content": Json::string("{\"answer\":\"paid\"}"),
        }),
      }),
    ]),
  })
  guard @openai.response(body) is Ok(FinalOutput(value)) else {
    fail("expected final output")
  }
  assert_eq(value, Json::object({ "answer": Json::string("paid") }))
}

///|
test "response decodes a tool call" {
  let body = Json::object({
    "choices": Json::array([
      Json::object({
        "message": Json::object({
          "tool_calls": Json::array([
            Json::object({
              "id": Json::string("call-1"),
              "function": Json::object({
                "name": Json::string("lookup_order"),
                "arguments": Json::string("{\"order_id\":\"ord-7\"}"),
              }),
            }),
          ]),
        }),
      }),
    ]),
  })
  guard @openai.response(body) is Ok(ToolCall(call)) else {
    fail("expected tool call")
  }
  assert_eq(call.name, "lookup_order")
  assert_eq(call.arguments, Json::object({ "order_id": Json::string("ord-7") }))
}
