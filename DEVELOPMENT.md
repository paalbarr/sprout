# 📐 SPR-002 — Sprout Coding Standards

| Field | Value |
|-------|-------|
| **Document ID** | SPR-002 |
| **Version** | 1.0  |
| **Status** | Final |
| **Authors** | Pablo Albarrán |
| **Audience** | Core maintainers, module developers, infrastructure engineers, contributors, AI coding agents |
| **Last Updated** | 2026-07-08 |

---

# 1. Purpose

This document defines the programming standards for the reference implementation of Sprout.

Its purpose is to ensure that every contribution remains portable, deterministic, maintainable, and compatible with the architectural principles defined in **SPR-001 — Sprout Architecture Specification**.

This document defines implementation standards only.

Whenever this document conflicts with the Architecture Specification, the Architecture Specification SHALL prevail.

---

# 2. Design Goals

The reference implementation SHALL prioritize:

- portability
- determinism
- readability
- maintainability
- simplicity
- reproducibility

Performance optimizations SHALL NOT compromise portability.

---

# 3. Shell Standard

The reference implementation SHALL conform to:

**IEEE Std 1003.1-2024 (POSIX.1)**

Every executable script SHALL execute correctly using:

```sh
/bin/sh
```

The implementation SHALL remain compatible with any POSIX-compliant shell.

---

# 4. Portability

The implementation SHALL NOT rely on operating-system specific behavior.

Scripts SHALL execute without modification on POSIX-compliant systems, including environments such as:

- Linux
- macOS
- BSD
- BusyBox
- Alpine Linux
- Raspberry Pi OS

Implementation behavior SHALL NOT depend on GNU-specific extensions.

---

# 5. Shell Compatibility

The implementation SHALL NOT require:

- Bash
- Zsh
- Fish
- Ksh
- shell-specific extensions

Compatibility with these shells is acceptable provided that only POSIX behavior is used.

---

# 6. Prohibited Shell Features

The following language features SHALL NOT be used.

## Bash Arrays

```bash
array=(a b c)
```

---

## [[ ]]

```bash
[[ expression ]]
```

---

## Arithmetic Evaluation

```bash
(( expression ))
```

---

## source

Use:

```sh
. file
```

instead.

---

## function keyword

Use:

```sh
name()
```

instead.

---

## mapfile / readarray

Not permitted.

---

## local

Not permitted.

Functions SHALL avoid shell-specific local variables.

---

## Associative Arrays

Not permitted.

---

## Brace Expansion

```bash
{1..10}
```

Not permitted.

---

# 7. External Commands

Scripts SHOULD prefer POSIX utilities.

Examples include:

- printf
- test
- find
- grep
- sed
- awk
- cut
- sort
- tr

The implementation SHOULD avoid GNU-specific options unless equivalent POSIX behavior exists.

---

# 8. Error Handling

Every executable script SHALL:

- terminate immediately after unrecoverable errors;
- return meaningful exit codes;
- print human-readable error messages;
- avoid silent failures.

Errors SHALL be deterministic.

---

# 9. Function Design

Functions SHALL:

- perform one responsibility;
- avoid hidden side effects;
- return meaningful exit status;
- avoid unnecessary global state.

Functions SHOULD remain short and focused.

---

# 10. Variables

Variable names SHALL:

- use lowercase
- use snake_case
- be descriptive

Constants SHALL use:

```sh
UPPER_CASE
```

Temporary variables SHOULD be minimized.

---

# 11. Quoting

Variable expansion SHALL always be quoted unless word splitting is explicitly required.

Preferred:

```sh
"$variable"
```

Avoid:

```sh
$variable
```

---

# 12. Command Substitution

Use:

```sh
$(command)
```

Never use:

```sh
`command`
```

---

# 13. Output

Diagnostic messages SHALL be written to:

```sh
stderr
```

Normal output SHALL be written to:

```sh
stdout
```

---

# 14. Dependencies

Every external dependency SHALL satisfy at least one of the following:

- required by POSIX;
- installed automatically by Sprout;
- explicitly documented.

Hidden dependencies SHALL NOT exist.

The following tools constitute the reference validation pipeline.

| Tool | Purpose |
|------|---------|
| shfmt | Source formatting |
| ShellCheck | Static analysis |
| POSIX Shell | Compatibility validation |
| Git | Source control |
| Docker | Runtime validation (when applicable) |

A contribution SHALL NOT be merged if any mandatory validation fails.

---

# 15. Code Documentation

Source code SHALL be self-explanatory whenever practical. Comments SHALL complement the code by explaining intent, assumptions, constraints, or non-obvious decisions, rather than describing obvious implementation details.

## General Rules

Comments SHALL:

- explain **why**, not **what**;
- be concise, accurate, and maintained with the code;
- use English;
- avoid redundant or obsolete information.

Outdated or misleading comments SHALL be removed.

## Function Documentation

Every public function SHALL include a documentation header describing:

- purpose;
- parameters;
- return value;
- side effects (if any);
- expected exit status (when applicable).

Example:

```sh
#
# Starts the Runtime and validates all required services.
#
# Arguments:
#   None
#
# Returns:
#   0 on success, non-zero on failure.
#
start_runtime() {
    ...
}
```

## Inline Comments

Inline comments SHOULD be used only when the intent of the code is not immediately obvious.

Preferred:

```sh
# Retry because the service may require a few seconds to become available.
```

Avoid:

```sh
# Increment counter.
counter=$((counter + 1))
```

## TODO Comments

Temporary work SHALL use the following format:

```text
TODO: Short description.
FIXME: Short description.
```

TODO and FIXME comments SHOULD reference an issue or tracking identifier when available.

## Documentation Quality

Documentation SHALL remain synchronized with the implementation. Changes affecting behavior, interfaces, or assumptions SHALL update the corresponding comments during the same change set.

Code requiring excessive comments to be understood SHOULD be refactored to improve readability.

---

# 16. Logging

All user-visible messages generated by the CLI, Core, or Modules SHALL follow a consistent format to ensure readability, deterministic behavior, and machine compatibility.

## Log Format

Every message SHALL use the following structure:

```text
[LEVEL] [COMPONENT] Message.
```

Example:

```text
[INFO]  [Core] Runtime initialized.
[WARN]  [Runtime] Existing configuration detected.
[ERROR] [Garden] Failed to download module index.
[FATAL] [Core] Runtime startup failed.
```

## Log Levels

| Level | Purpose |
|--------|---------|
| TRACE | Detailed execution tracing (disabled by default). |
| DEBUG | Diagnostic information. |
| INFO | Normal operation. |
| WARN | Recoverable condition. |
| ERROR | Operation failed. |
| FATAL | Unrecoverable error. Execution terminates. |

## Components

Component names SHALL identify the origin of the message. Recommended names include:

- CLI
- Core
- Runtime
- Garden
- Provisioning
- Validation
- Recovery

Modules SHOULD use their module name (e.g. `PostgreSQL`, `Ollama`).

## Message Rules

Messages SHALL:

- begin with a capital letter;
- end with a period;
- be concise and actionable;
- avoid implementation details unless DEBUG or TRACE is enabled.

Long-running operations SHOULD report progress.

Error messages SHOULD describe both the failure and, when possible, the corrective action.

## Output Streams

| Level | Stream |
|--------|--------|
| INFO | stdout |
| TRACE, DEBUG, WARN, ERROR, FATAL | stderr |

## Colors

ANSI colors MAY be used for interactive terminals but SHALL be automatically disabled when output is redirected or unsupported. Color SHALL improve readability only and MUST NOT convey meaning by itself.

## Structured Output

Human-readable logs SHALL be the default output. Machine-readable formats (e.g. JSON) SHALL only be emitted when explicitly requested.
