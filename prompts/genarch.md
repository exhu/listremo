Scan this repository and generate a concise `ARCHITECTURE.md` file at the project root designed to orient AI coding agents in minimal tokens.

### Step 1: Efficient Exploration
1. Inspect dependency and build files (`dub.json`)
2. Map the directory structure (ignoring `.git`, `node_modules`, `venv`, `target`, `dist`, `build`, and lockfiles).
3. Read application entry points, key interfaces to understand how data and control flow through the system.

### Step 2: Generate `ARCHITECTURE.md`
Write `ARCHITECTURE.md` using the exact structure below. Keep the entire file **under 150 lines**, using dense bullet points instead of long prose:

1. **System Overview & Tech Stack**: 2–3 sentences explaining what the application does, its architectural paradigm (e.g., layered MVC, hexagonal, event-driven, CLI pipeline), and core technologies/frameworks.
2. **Source Tree & Module Responsibilities**: A directory and key boundary-file map. State the single responsibility of each major folder and list only critical entry/boundary files (do not list every single file).
3. **Core Data & Execution Flow**: Concise step-by-step traces (e.g., `Entry -> Parser -> Service -> Storage`) showing how primary operations execute.
4. **Architectural Boundaries & Invariants**: Non-negotiable rules derived from the codebase (e.g., where state lives, how errors are handled, strict layer import rules, database/API client boundaries).
5. **Development & Verification Commands**: Exact shell commands to build, lint, type-check, and run single or full test suites.

Constraint: Only document patterns and commands that actually exist in the repository—do not invent aspirational rules.
