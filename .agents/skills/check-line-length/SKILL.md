---
name: check-line-length
description: >-
  Checks that D source files and markdown documentation adhere to the project's
  80-column line length rule. Run via rdmd.
---

# Check Line Length Skill

Verifies that source code and documentation files do not exceed the 80 columns
per line limit defined in `codestyle.md` and `AGENTS.md`.

## Usage

Run the D script using `rdmd`:

```bash
# Check default targets (source directory and implementation doc)
rdmd --compiler=ldc2 \
  .agents/skills/check-line-length/scripts/check_line_length.d

# Or check specific files / directories
rdmd --compiler=ldc2 \
  .agents/skills/check-line-length/scripts/check_line_length.d \
  source/ spec/plan1-implementation.md
```

## Behavior

- Exits with `0` if all inspected files adhere to the 80-column rule.
- Exits with `1` and prints file paths, line numbers, and line lengths if any
  line exceeds 80 columns.
