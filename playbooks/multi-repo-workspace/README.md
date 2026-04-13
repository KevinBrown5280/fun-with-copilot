# Multi-Repository Workspace

A pattern for giving AI coding agents full context across a bounded context that spans
multiple Git repositories — without duplicating clones or coupling them.

## The problem

Feature teams typically own a bounded context that spans several repositories: a frontend,
one or more APIs, environment configs, shared libraries. AI agents launched in any one of
those repos only see that repo — they miss cross-service relationships, shared conventions,
and end-to-end data flows.

The fix is a lightweight workspace repo that surfaces all component repos side by side,
with a `copilot-instructions.md` that gives the agent the full picture.

## Why junctions instead of clones

The [original pattern](https://tech-talk.the-experts.nl/a-simple-pattern-for-ai-powered-multi-repository-development-62176dc14bfe)
places repos inside the workspace via `git clone`. That works, but has a cost: you get a
separate copy of every repo per workspace. If the same repo belongs to more than one
workspace (e.g., a shared platform repo that appears in a "full stack" workspace *and* a
"client integration" workspace), clones diverge and require separate pulls.

**Junctions eliminate this.** Each repo lives in exactly one place on disk. Any number
of workspaces can reference it. `git pull` in the real repo is instantly visible in every
workspace that junctions to it. No duplication, no sync drift.

## When to use

- Your team owns a bounded context spanning 2+ repositories
- You want AI agents to reason across the full stack (UI, API, config, infra)
- The same repos appear in more than one workspace combination
- You want cross-repo context without the overhead of git submodules

**Don't bother for:** a single-repo project, or a one-off workspace you'll clone once
and throw away.

## Caveats

- **One branch per checkout.** A junction points to a real directory, not a snapshot.
  If two workspaces junction the same repo, switching branches in one affects the other.
  Plan workspace combos with that in mind.
- **Per-machine setup.** Junctions are filesystem artifacts, not tracked by Git. Anyone
  who clones the workspace repo must recreate junctions against their own local paths.
  Committing a `createjunctions.ps1` invocation (or a wrapper script with your paths) is
  the easiest way to document the setup for others.
- **Agent traversal assumption.** This pattern relies on your AI agent following NTFS
  junctions transparently when indexing files. Most current agents do. If yours sandboxes
  file access or limits traversal depth, verify it can see junction contents before
  relying on this pattern.

## Directory layout

```
my-workspace/                        ← workspace repo (its own Git history)
├── .git/
├── .gitignore                       ← lists junction names to keep status clean
├── .github/
│   └── copilot-instructions.md      ← agent context for the full bounded context
├── createjunctions.ps1              ← optional: workspace setup script
├── repo-a/                          ← junction → C:\Git\repo-a
├── repo-b/                          ← junction → C:\Git\repo-b
└── repo-c/                          ← junction → C:\Git\repo-c
```

The workspace repo itself tracks almost nothing — just `.gitignore`,
`copilot-instructions.md`, and any workspace-level scripts or specs. The component
repos manage themselves.

## Setup

### 1. Create the workspace repo

```
mkdir my-workspace
cd my-workspace
git init
```

### 2. Create junctions

Use the included [`createjunctions.ps1`](createjunctions.ps1):

```powershell
.\createjunctions.ps1 `
    -WorkspaceRoot "C:\Workspaces\my-workspace" `
    -SourceRoot    "C:\Git" `
    -Projects      "repo-a", "repo-b", "repo-c"
```

Supports deep paths — the junction is named after the last path segment:

```powershell
# Creates my-workspace\repo-a  and  my-workspace\MyComponent
.\createjunctions.ps1 `
    -WorkspaceRoot "C:\Workspaces\my-workspace" `
    -SourceRoot    "C:\Git" `
    -Projects      "repo-a", "big-monorepo\src\MyComponent"
```

> **Note:** Uses NTFS junctions, which require no elevated privileges or Developer Mode.
> Do not use `New-Item -ItemType SymbolicLink` — that requires Developer Mode or admin rights.

### 3. Update `.gitignore`

Git can traverse junctions and stage files from the target repo if you run `git add .`
before ignoring them. Update `.gitignore` **before** your first `git add`:

```gitignore
/repo-a/
/repo-b/
/repo-c/
```

This keeps `git status` clean and prevents accidentally committing junction contents.

### 4. Create `.github/copilot-instructions.md`

This is the highest-value part. See [copilot-instructions-template.md](copilot-instructions-template.md)
for a starter. Consider covering:

- **Components table** — each repo's path and purpose in one glance
- **Architecture** — a text diagram of data flow between components
- **How components connect** — which calls which, what auth/proxy mechanism, where config lives
- **Ignore hints** — large monorepos often have legacy folders; tell the agent to ignore them explicitly
- **Where to make changes** — a table mapping change type to the right repo/path
- **Cross-project change order** — which repo to change first and why
- **Local development** — ports, startup order, proxy config

> **Nested instructions:** Component repos may have their own `.github/copilot-instructions.md`.
> Those apply when a repo is opened directly. When working from the workspace root, the
> agent loads the workspace-level file. Include any repo-specific conventions relevant to
> cross-repo work in the workspace-level file.

## Tips from real usage

- **One workspace per bounded context, not per feature.** The workspace is a long-lived
  view of your platform, not a per-branch scratchpad.
- **Multiple workspaces can share the same junction target.** A "full platform" workspace
  and a "client integration" workspace can both junction to `shared-repo` without conflict.
  Each workspace just presents a different combo of repos.
- **Deep-path junctions are useful for large monorepos.** If only
  `big-repo\src\MyComponent` is relevant, junction directly to that subfolder rather
  than exposing the entire monorepo to the agent.
- **Keep workspace-level artifacts here.** Architecture decision records, cross-cutting
  specs, runbooks, and test results are natural residents of the workspace repo.
- **Ignore hints matter.** If a monorepo has large legacy subtrees, explicitly tell the
  agent to ignore them in `copilot-instructions.md`. The agent will scan less and reason
  better.
- **Never use `Remove-Item -Recurse` on a junction.** It will delete the contents of the
  target directory, not just the junction link. To remove a junction safely:
  `Remove-Item <junction-path>` with no `-Recurse` flag.

## Credits

Pattern adapted from
[A simple pattern for AI-powered multi-repository development](https://tech-talk.the-experts.nl/a-simple-pattern-for-ai-powered-multi-repository-development-62176dc14bfe)
by Maik Kingma, with the addition of junctions to support reuse across multiple
workspace combinations without duplication.
