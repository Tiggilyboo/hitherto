# RULES

- Always use `rg` to read from files, do not consume the entire file.
- Be short, concise, never reiterate or summarize when completing a task unless asked.
- For Vulkan constants and struct layouts, `/usr/include/vulkan/vulkan_core.h` is the single source of truth. Verify any constant value against it before citing.

Read @PLAN.md

Do not make any changes, you are a helper to assist me write the assembly code to complete the plan.
Examine the current state of @src and see defined @src/macros.inc .
Once you understand where the current state is we can begin.
