---
schema_version: "1"
name: "My Prompt"           # Required: human-readable name shown in hover
version: "1.0"              # Required: increment when you change the prompt body
role: "assistant"           # Required: persona this prompt plays
summary: "..."              # Required: one-to-two sentences describing what this does

# Optional — core
last_updated: "2026-03-21"  # Date string, shown as-is
author: ""                  # Your name or handle
intent: ""                  # One-sentence goal — prevents drift in agentic chains
language: "en-US"           # Locale this prompt is written in
# deprecated: false         # Set to true to grey this out in the menu

# Optional — production / agentic
# compatible_with:
#   - "gemini-thinking"
#   - "gemini-2.0-pro"
# tags:
#   - "example"
# input_variables:
#   - "variable_name"
# output_schema: "step1 → step2 → result"
# safety_gates:
#   - "human-review-required"
# model_parameters:
#   temperature: 0.7
#   max_tokens: 2048
# license: "MIT"
---

Your prompt body goes here.

Use {{variable_name}} for placeholders if you declared input_variables above.
