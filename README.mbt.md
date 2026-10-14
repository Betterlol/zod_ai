# zod_ai

`zod_ai` is a schema-first Agent runtime for MoonBit. It uses
[`moon_zod`](https://mooncakes.io/docs/Betterlol/moon_zod) as the single runtime
contract for model tool arguments, tool results, and final Agent output.

The current MVP is deliberately transport-independent: a provider adapter is a
`Model` function that receives the conversation and JSON Schema tool
definitions, then returns either a tool call or a final JSON value. This makes
the runtime deterministic to test with a fixed Mock Model.

## What works

- `ToolContract` contains a name, description, input schema, output schema and
  execution function.
- Tool input is validated before execution; all moon_zod field errors are sent
  back as one repair prompt.
- Tool output is validated before it becomes model-visible data.
- Final output is separately validated and repaired with its own retry budget.
- A bounded model turn count prevents loops from running forever.
- Tools can be allowed, rejected, or stopped for explicit approval before they
  execute.
- Tool definitions export their input schema as standard JSON Schema.
- `tool_with_context` receives per-run JSON dependencies, prompt, transcript,
  call ID and turn number; use `run_with_deps` to supply dependencies.
- `ToolSet` composes reusable groups while rejecting duplicate names.
- Completed runs record model responses and can be replayed deterministically.
- Local tools export MCP `inputSchema` definitions and MCP client callbacks can
  be adapted with `mcp_tool`.

## Run the example

```bash
moon test
moon run cmd/main
```

The order-assistant example intentionally emits an invalid `order_id` on its
first model response. The Agent adds moon_zod's field-level repair prompt to
the message history, accepts the corrected second call, and returns a validated
structured result.

For deterministic tests, `mock_model([response_1, response_2, ...])` turns a
fixed response sequence into a `Model` and fails explicitly if the Agent makes
an unexpected extra request.

## Minimal shape

```moonbit nocheck
let lookup = @zod_ai.tool(
  "lookup_order",
  "Look up an order by its identifier.",
  @moon_zod.object({ "order_id": @moon_zod.string().min(1) }).strict(),
  @moon_zod.object({ "status": @moon_zod.string() }).strict(),
  lookup_order,
)

let agent = @zod_ai.agent(
  [lookup],
  @moon_zod.object({ "action": @moon_zod.string() }).strict(),
)

match agent.run(model, "Where is order ord-7?") {
  Ok(result) => println(result.output.stringify(indent=2))
  Err(_) => println("The Agent did not produce a valid result.")
}
```

Use `tool_with_policy(..., @zod_ai.require_approval(), ...)` for a tool that
must stop at an approval boundary. The runtime returns `ApprovalRequired` with
the validated call and resumable transcript; call
`agent.resume_after_approval(model, request, true)` after an explicit approval.
Cross-process persistence of that request remains an adapter concern.
