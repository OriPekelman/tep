# Project notes for AI assistants (Claude Code, Cursor, etc.)

This project develops on a **Mac** but runs on the **gx10** — an NVIDIA
GB10 / Grace Blackwell box at home (121 GiB unified memory, on Tailscale,
hostname `gx10`). The Mac you're running on **does not have a GPU**, so
**you must execute code on the gx10**, not locally.

## Where am I? (read this first)

Run `hostname -s` once at session start to identify the side you're on.
That's also what `gx-run` / `gx-sync` use to short-circuit when invoked
on the box itself, so it's the canonical check.

- **`hostname -s` returns `gx10`** → you're on the **gx10 (runtime)**.
  **Stop and read `~/.claude/CLAUDE.md`** for the gx10-side conventions
  before you do anything else. In particular: `~/sites/<project>/` here
  is a rsync target from the Mac and **edits to source files get
  overwritten on the next sync** — don't fix typos in place. There is
  no `.git/` on this side; commit history lives on Mac only.
- **anything else** (typically a Mac, returns something like
  `<your-mac>`) → you're on the **Mac (editor)**. The rest of this file
  describes your workflow: edit here, delegate execution to `gx-run`.
  Keep going.

## How to run code (the only correct way)

Use the `gx-run` wrapper installed at `~/gx10_config/bin/gx-run`:

```sh
gx-run python train.py        # syncs project + runs in container on gx10, in tmux
gx-run pytest                 # tests, GPU available
gx-run --shell                # interactive shell in the dev container
gx-run --no-sync python ...   # don't re-sync (e.g., resuming a prev run)
```

What `gx-run` does:
1. `rsync` the current dir → `gx10:~/sites/<project>/` (excludes `.git`,
   virtualenvs, `__pycache__`, `node_modules`, plus everything in
   `.gitignore`).
2. SSH to gx10, run the command via `docker compose run --rm dev <cmd>`,
   inside a `tmux` session named after the project.
3. Stream stdout/stderr back to the local terminal.

Because the actual run is in tmux on the box, **closing the local
terminal does NOT kill the job**. Re-attach later with:

```sh
ssh gx10
tmux attach -t <project-name>
```

## File locations

| What | Container path | Host path on gx10 |
|---|---|---|
| Project source | `/workspace` | `~/sites/<project>/` |
| Big ephemeral data, datasets | `/scratch` | `/srv/data/scratch/` |
| Ollama model cache (read-only) | `/models` | `/srv/data/models/` |
| HF cache (shared across projects) | `/root/.cache/huggingface` | named volume `hf_cache` |

Outputs you want to keep go under `/workspace` (i.e., the project dir);
they sync back to the Mac on the next `gx-run` (rsync is one-way, so use
`gx-sync --pull` to fetch them — see `~/gx10_config/docs/dev-workflow.md`).

## Anti-patterns — DO NOT DO THESE

- ❌ **Run `python …` directly on the Mac.** No GPU, missing CUDA libs,
  may silently use CPU and produce wrong/slow results. Always `gx-run`.
- ❌ **`pip install` on the Mac for project deps.** Add to the project's
  `requirements.txt` and re-run; or `gx-run --shell` and `pip install
  --user <pkg>` (the image has `PIP_USER=1`, so user-site installs
  persist).
- ❌ **Write large outputs outside `/workspace` or `/scratch`.** The
  container is ephemeral; only mounted volumes survive.
- ❌ **Try to `docker run` on the Mac.** No NVIDIA runtime. Use `gx-run`.

## When to deviate

- **Pure code edits, formatting, linting, tests with no CUDA**: fine to
  do locally on the Mac (`black`, `ruff`, `mypy`, simple unit tests).
- **Anything that imports torch / transformers / datasets**: `gx-run`.
- **Anything that calls a Hugging Face model** (even a small one):
  `gx-run` — the cache is on the box.

## Updating this file

Customize this `CLAUDE.md` for the project's specific entrypoints (e.g.
`gx-run python -m myproj.train --config configs/dev.yaml`). The general
gx10 dev workflow lives in `~/gx10_config/docs/dev-workflow.md` — link
to it for context, don't duplicate.
