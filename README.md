# Symphony

Symphony is an autonomous agent orchestration service by OpenAI. It polls Linear for issues, creates isolated workspaces, and runs Codex coding agents to implement the work end-to-end. You manage tickets — Symphony manages agents.

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](.github/media/symphony-demo.mp4)

_In this [demo video](.github/media/symphony-demo.mp4), Symphony monitors a Linear board for work and spawns agents to handle the tasks. The agents complete the tasks and provide proof of work: CI status, PR review feedback, complexity analysis, and walkthrough videos. When accepted, the agents land the PR safely. Engineers do not need to supervise Codex; they can manage the work at a higher level._

> [!WARNING]
> Symphony is a low-key engineering preview for testing in trusted environments.

---

## Get Running in 5 Minutes

### Prerequisites

| Tool | Why |
|------|-----|
| [mise](https://mise.jdx.dev/) | Manages Elixir/Erlang versions |
| `LINEAR_API_KEY` | Linear API access — [create one here](https://linear.app/settings/api) |
| [codex](https://github.com/openai/codex) | OpenAI's coding agent CLI |

### Setup

```bash
git clone https://github.com/stussysenik/symphony
cd symphony/elixir

# Install Elixir/Erlang via mise
mise trust && mise install

# Fetch deps + compile
mise exec -- mix setup
mise exec -- mix build
```

### Configure

```bash
# Set your Linear API key
export LINEAR_API_KEY=lin_api_...

# Edit WORKFLOW.md — set your project_slug
$EDITOR WORKFLOW.md
```

In `WORKFLOW.md`, change the `project_slug` under `tracker:` to match your Linear project.

### Run

```bash
./bin/symphony ./WORKFLOW.md --port 4000
```

Open [localhost:4000](http://localhost:4000) — you're live.

---

## What You Can Do

### Automate any Linear project

Point at a project slug, Symphony handles the rest:

- Polls for Todo / In Progress issues on a configurable interval
- Creates an isolated git workspace per issue
- Launches a Codex agent per workspace
- Multi-turn agent sessions (up to 20 turns by default)
- Retries with exponential backoff on transient failures

### See everything happening — real-time dashboard

- Phoenix LiveView at `localhost:<port>`
- Per-issue detail views with event timelines
- Token usage tracking per run
- JSON API for scripting:

```bash
curl localhost:4000/api/v1/state | jq      # all issues
curl localhost:4000/api/v1/MT-123 | jq     # single issue
```

### Configure everything in one file — `WORKFLOW.md`

- **YAML front matter**: tracker, polling, workspace, hooks, agent limits, codex policies
- **Liquid-style prompt templates**: `{{ issue.title }}`, `{{ issue.description }}`
- **Lifecycle hooks**: clone repos, install deps, run setup scripts
- **Hot-reloadable** — edit while running, changes apply on next poll

### Agent skills — pre-built in `.codex/skills/`

| Skill | What it does |
|-------|-------------|
| `linear` | Read/write Linear via GraphQL (comments, state changes, file uploads) |
| `commit` | Clean conventional commits with co-author trailers |
| `push` | Push + auto-create PRs with template validation |
| `pull` | Merge upstream with zdiff3 conflict resolution |
| `land` | Watch CI, handle reviews, squash-merge when green |
| `debug` | Triage stuck runs via log correlation |

### Fork extras (this repo)

- Phoenix dashboard with live event stream
- Visual asset pipeline (Linear attachments → multimodal Codex prompts)
- Ingestion summary logging with token deltas
- SSH worker support for remote agent execution

Operator interface and workflow configs: **[symphony-hub](https://github.com/stussysenik/symphony-hub)**

---

## Branching Strategy

| Branch | Purpose | Tracks | Directory |
|--------|---------|--------|-----------|
| `main` | Pure upstream sync | `upstream/main` | `symphony/` |
| `mirror` | Stable customizations (default) | `origin/mirror` | `symphony-mirror/` |
| `dev` | Active development | `origin/dev` | `symphony-dev/` |

**Three rules:**

1. Never commit to `main` — only sync from upstream
2. `mirror` is your real main — merge upstream into it when ready
3. `dev` is where you work — merge to mirror when stable

---

## Commands Cheat Sheet

```bash
# Run Symphony
./bin/symphony ./WORKFLOW.md --port 4000

# Dev quality gate (format, lint, test, dialyzer)
cd elixir && make all

# Sync upstream into main
cd symphony/ && git fetch upstream && git merge upstream/main && git push origin main

# Merge upstream changes into mirror
cd symphony-mirror/ && git merge origin/main && git push origin mirror

# Debug a specific ticket
rg "issue_identifier=MT-123" log/symphony.log*
curl localhost:4000/api/v1/MT-123 | jq
```

---

## Minimal WORKFLOW.md Example

The smallest config to get running:

```yaml
---
# -- Tracker: which Linear project to poll --
tracker:
  kind: linear
  project_slug: "your-project-slug"          # Linear project URL slug
  active_states: [Todo, In Progress]
  terminal_states: [Done, Cancelled]

# -- Polling: how often to check for new work --
polling:
  interval_ms: 5000

# -- Workspace: where agent workspaces live --
workspace:
  root: ~/code/symphony-workspaces

# -- Hooks: shell scripts for workspace lifecycle --
hooks:
  after_create: |
    git clone --depth 1 https://github.com/your-org/your-repo .
    npm install   # or whatever setup your project needs

# -- Agent: concurrency and turn limits --
agent:
  max_concurrent_agents: 5
  max_turns: 20

# -- Codex: how to launch the coding agent --
codex:
  command: codex app-server
  approval_policy: never
  thread_sandbox: workspace-write
---

You are an autonomous coding agent working on {{ issue.identifier }}: {{ issue.title }}.

{{ issue.description }}

Complete the work, commit, push, and create a PR.
```

See [elixir/WORKFLOW.md](elixir/WORKFLOW.md) for the full production config with all options.

---

## Key Files

| File | Purpose |
|------|---------|
| [`elixir/WORKFLOW.md`](elixir/WORKFLOW.md) | Agent orchestration config — the one file you customize |
| [`elixir/README.md`](elixir/README.md) | Official Elixir implementation setup instructions |
| [`SPEC.md`](SPEC.md) | Language-agnostic architecture spec (build your own) |
| [`.codex/skills/`](.codex/skills/) | Pre-built agent skills (commit, push, pull, land, linear, debug) |

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).
