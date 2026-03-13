Update all LangChain project documents by running the three individual update skills in sequence

## Documents

The LangChain LLM-as-a-Judge project has three design documents in `ai-specs/projects/engineering/langchain/`:

| Document | Responsibility | Language |
|----------|---------------|----------|
| `architecture.md` | Architecture, design decisions (What/Why) | Japanese |
| `progress.md` | Phase progress tracking (Status) | English |
| `ops.md` | Setup procedures, operations, gotchas (How) | Japanese |

## Procedure

Run each of the following skills in order. For each skill, complete the full cycle (gather → propose → confirm → apply) before moving to the next.

1. **`/update-langchain-progress`** — Update phase progress first (other docs may reference it)
2. **`/update-langchain-design`** — Update design decisions
3. **`/update-langchain-ops`** — Update infrastructure and operations

If a skill finds no changes needed, skip it and move to the next.

## Rules

- Each skill has its own target file search logic and can work even without all repos cloned locally
- Always complete one skill's update cycle before starting the next
- Do not mix content between the three documents — respect their responsibility boundaries
