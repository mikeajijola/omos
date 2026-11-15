# Configured provider reasoning

For an OpenAI-compatible connection in `~/.fx/settings.json`, declare only the
reasoning values verified for each model. OMOS sends a selected value as
`reasoning_effort`; it does not infer support from a model name.

```json
{
  "providers": {
    "custom": {
      "protocol": "openai-chat-completions",
      "base_url": "https://provider.example/v1",
      "auth": { "type": "bearer", "env": "CUSTOM_API_KEY" },
      "reviewer_model": "review-model",
      "reviewer_effort": "low",
      "model_metadata": {
        "actor-model": { "reasoning_efforts": ["low", "medium", "high"] },
        "review-model": { "reasoning_efforts": ["low", "high"] }
      }
    }
  }
}
```

The actor uses the existing effort setting or `--effort`. An unsupported actor
value is rejected when the model has an explicit nonempty effort catalog.
Without a catalog, the existing behavior of omitting reasoning options remains.
The optional provider-level `reviewer_effort` controls automatic tool permission
review and native OMOS contract planning, progress checks, intent resolution, and
completion assessment, independently of the actor. It must be declared for the
selected reviewer model; otherwise review fails before sending a request.
A cross-provider `review_model` override uses the selected connection's
`reviewer_effort`. Omitting it keeps that provider's default.

Native OMOS CLI, UI, background workers, and MCP chat share this configuration.
The SDK's host-supplied `assess()` callback owns its model and inference settings;
this option does not configure that callback or enable contract governance in
ACP. Actor conversation routing retains its existing inference options.

An empty `reasoning_efforts` array advertises no reasoning controls. Values must
be unique, nonempty labels, with at most 16 values per model; `auto`, `default`,
and `adaptive` are not wire values. These settings change inference options only:
permission checks, exact-action review, and independent completion verification
remain enabled. Provider support can differ between models; verify options before
adding them to a catalog.


The parser is [configured_provider.zig](configured_provider.zig), and request
projection belongs to [chat_completions_protocol.zig](../../gateway/chat_completions_protocol.zig).
The native wire behavior is covered by
[configured-providers.test.ts](../../../tests/e2e/configured-providers.test.ts)
and [workspace-ui-host.test.ts](../../../tests/e2e/workspace-ui-host.test.ts).
