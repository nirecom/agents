# Plan Principles

Three meta-principles applied **before** drafting an outline or detail plan.
Read this at /make-outline-plan and /make-detail-plan stages, and whenever
adding or modifying a file in a family (hooks, sentinels, rules, env entries,
cross-platform installers, etc.).

## 1. Elevate Perspective

Before fixing or adding, raise the abstraction one level above the immediate
task and check exhaustively whether the same problem occurs in other cases.

**Apply when:**
- Changing a pattern, regex, or convention.
- Fixing a bug — the same bug may exist in symmetric places.
- Adding a new rule, hook, sentinel, skill, or config entry.

**How:**
1. Name the class the immediate target belongs to ("this is one of N
   sentinels", "this is one of M hooks").
2. Enumerate the other members of that class.
3. Check each — does the change apply there too? Does the bug exist there?
4. Decide per member: apply, skip with reason, or surface as follow-up.

**Anti-pattern:** Fixing case A while leaving symmetric cases B, C, D
untouched because the user did not explicitly point at them. If the user
has to enumerate each symmetric case for you, you skipped §1.

## 2. Orthogonality

§1 applied to symmetric pairs / families: when pattern X is required in
case A, ensure all symmetric cases share the same treatment. The list
below is not exhaustive — apply §1 to discover new families.

### Known orthogonal pairs / families

- **`.env` ↔ `.env.example`** — variable add/remove/rename happens in
  both. `.env` is real secrets (never committed); `.env.example`
  documents required variables with placeholders.
- **Cross-platform** — when adding/modifying for one platform (e.g.
  `install/win/`), apply the equivalent change to other platforms
  (e.g. `install/linux/`) unless a platform-specific reason justifies
  skipping.
- **Naming** — when adding files in an existing convention (hooks,
  markers, config), follow the established naming pattern. Check
  existing counterparts before choosing a name.
- **Sentinel families (bare + reason forms)** — every sentinel in
  `settings.json` `ask` array must have both `<<SENTINEL>>` and
  `<<SENTINEL: *>>` entries, and the hook handler must treat both
  forms symmetrically (regex captures reason; bare emits soft warning
  for accountability).

Discovery of a new orthogonal family is itself an application of §1.
When you notice asymmetry, fix it and add the family here.

## 3. Name Reflects Substance

A file, function, variable, sentinel, or rule name must convey what it
contains. A reader who sees only the name should know what to expect
and when to consult it.

**Apply when:**
- Creating a new file, function, rule, sentinel, or config entry.
- Renaming an existing one.
- Reviewing a proposed name (yours or someone else's).

**Checks:**
- Does the name describe the contents precisely (not more, not less)?
- Does it collide with another name's scope? (Generic names like
  `design`, `utils`, `misc`, `helpers` typically do.)
- Will it be discovered at the right time? A rule needed at plan time
  should be findable when planning (e.g. `plan-` prefix).
- Does it follow the surrounding naming convention?

**Anti-pattern:** Names that swallow content from unrelated areas
(`design-principles.md` colliding with `architecture/design.md`),
or names that require reading the body to know what the file covers.
