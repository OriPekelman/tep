# experiments -- mock training-run manager driven by MCP tools.
#
# The full agentic-driver surface: Claude Code (or OpenCode /
# Gravity / any MCP client) discovers tools + resources via
# /mcp, runs experiments, polls metrics, cancels runs -- all via
# the natural agent-tool loop, no human-in-the-loop UI required.
#
# The runs are simulated (no actual ML). State lives in module-
# level arrays. A real version would persist to SQLite via the
# same exact tool/resource API.
#
# Run:
#   bin/tep build examples/experiments/app.rb -o /tmp/experiments
#   /tmp/experiments -p 4567
#
# Then point an MCP client at http://127.0.0.1:4567/mcp,
# or for non-MCP agents: http://127.0.0.1:4567/openapi.json +
# http://127.0.0.1:4567/llms.txt for discovery.
require 'sinatra'

# ---- mock experiment state ----

# Parallel arrays per experiment so spinel sees typed slots
# instead of an Array<Hash> with mixed value types.
EXP_IDS         = [0]; EXP_IDS.delete_at(0)
EXP_NAMES       = [""]; EXP_NAMES.delete_at(0)
EXP_LRS         = [""]; EXP_LRS.delete_at(0)
EXP_EPOCHS      = [0]; EXP_EPOCHS.delete_at(0)
EXP_CUR_EPOCH   = [0]; EXP_CUR_EPOCH.delete_at(0)
EXP_STATUS      = [""]; EXP_STATUS.delete_at(0)    # "queued" | "running" | "done" | "cancelled"
EXP_LOSS        = [""]; EXP_LOSS.delete_at(0)      # serialized loss-per-epoch, comma-joined

NEXT_ID = [0]

# Allocate a new experiment id, append all defaults.
def enqueue_experiment(name, lr_str, epochs)
  NEXT_ID[0] = NEXT_ID[0] + 1
  id = NEXT_ID[0]
  EXP_IDS.push(id)
  EXP_NAMES.push(name)
  EXP_LRS.push(lr_str)
  EXP_EPOCHS.push(epochs)
  EXP_CUR_EPOCH.push(0)
  EXP_STATUS.push("queued")
  EXP_LOSS.push("")
  id
end

# Linear scan -- O(n), fine for the demo since n stays small.
# Returns the array index for id, or -1 if not found.
def find_exp_index(id)
  i = 0
  while i < EXP_IDS.length
    if EXP_IDS[i] == id
      return i
    end
    i = i + 1
  end
  -1
end

# Format a single experiment as `id=N name=foo status=running lr=1e-3 epoch=3/10 loss=0.42,0.31`.
def format_experiment(i)
  "id="    + EXP_IDS[i].to_s +
  " name=" + EXP_NAMES[i] +
  " lr="   + EXP_LRS[i] +
  " status=" + EXP_STATUS[i] +
  " epoch=" + EXP_CUR_EPOCH[i].to_s + "/" + EXP_EPOCHS[i].to_s +
  " loss=" + EXP_LOSS[i]
end

# Simulate one epoch of training -- bump cur_epoch + append a
# synthetic loss value. When epoch == epochs, flip status to done.
def step_experiment(i)
  if EXP_STATUS[i] == "running"
    EXP_CUR_EPOCH[i] = EXP_CUR_EPOCH[i] + 1
    # Synthetic loss: starts around 1.0, decays ~10% per step.
    base_x100 = 100 - (EXP_CUR_EPOCH[i] * 10)
    if base_x100 < 1
      base_x100 = 1
    end
    new_loss = "0." + base_x100.to_s
    if EXP_LOSS[i].length > 0
      EXP_LOSS[i] = EXP_LOSS[i] + "," + new_loss
    else
      EXP_LOSS[i] = new_loss
    end
    if EXP_CUR_EPOCH[i] >= EXP_EPOCHS[i]
      EXP_STATUS[i] = "done"
    end
  end
  0
end

# ---- MCP tools ----

mcp_tool 'start_experiment', "Enqueue a new training run", caps: [:run_experiments] do
  param :name,          String,  "experiment name (free-text label)"
  param :learning_rate, String,  "learning rate as string (e.g. '1e-3', '0.001')"
  param :epochs,        Integer, "number of training epochs"

  on_call do |name:, learning_rate:, epochs:|
    id = enqueue_experiment(name, learning_rate, epochs)
    idx = find_exp_index(id)
    # Auto-advance to running for the demo. A real runner would
    # background this and update status as worker fibers progress.
    EXP_STATUS[idx] = "running"
    Tep::MCP.text("started experiment id=" + id.to_s + " (" + name + ")")
  end
end

mcp_tool 'step_experiment', "Advance one experiment by one epoch" do
  param :id, Integer, "experiment id to advance"

  on_call do |id:|
    idx = find_exp_index(id)
    if idx < 0
      Tep::MCP.error("no such experiment id=" + id.to_s)
    else
      step_experiment(idx)
      Tep::MCP.text(format_experiment(idx))
    end
  end
end

mcp_tool 'list_experiments', "List all experiments + their current state" do
  on_call do
    if EXP_IDS.length == 0
      Tep::MCP.text("no experiments yet")
    else
      out = ""
      i = 0
      while i < EXP_IDS.length
        if i > 0
          out = out + "\n"
        end
        out = out + format_experiment(i)
        i = i + 1
      end
      Tep::MCP.text(out)
    end
  end
end

mcp_tool 'cancel_experiment', "Mark an experiment as cancelled", caps: [:run_experiments] do
  param :id, Integer, "experiment id to cancel"

  on_call do |id:|
    idx = find_exp_index(id)
    if idx < 0
      Tep::MCP.error("no such experiment id=" + id.to_s)
    else
      EXP_STATUS[idx] = "cancelled"
      Tep::MCP.text("cancelled id=" + id.to_s)
    end
  end
end

# ---- MCP resources ----

mcp_resource 'experiments/all', "Snapshot of every experiment" do
  on_read do
    body = ""
    i = 0
    while i < EXP_IDS.length
      if i > 0
        body = body + "\n"
      end
      body = body + format_experiment(i)
      i = i + 1
    end
    Tep::MCP.resource_text("experiments/all", body)
  end
end

mcp_resource 'experiments/active', "Currently-running experiments" do
  on_read do
    body = ""
    i = 0
    while i < EXP_IDS.length
      if EXP_STATUS[i] == "running"
        if body.length > 0
          body = body + "\n"
        end
        body = body + format_experiment(i)
      end
      i = i + 1
    end
    if body.length == 0
      body = "no active experiments"
    end
    Tep::MCP.resource_text("experiments/active", body)
  end
end

# Plain HTTP landing for humans poking around.
get '/' do
  res.headers["Content-Type"] = "text/plain; charset=utf-8"
  "experiments demo (tep MCP battery)\n" +
  "\n" +
  "Catalog: /llms.txt\n" +
  "OpenAPI: /openapi.json\n" +
  "MCP:     POST /mcp (JSON-RPC 2.0)\n" +
  "\n" +
  "Tools:\n" +
  "  POST /tools/start_experiment   (requires X-Test-Cap-Run header below)\n" +
  "  POST /tools/step_experiment\n" +
  "  POST /tools/list_experiments\n" +
  "  POST /tools/cancel_experiment  (capped)\n" +
  "\n" +
  "Resources:\n" +
  "  GET  /resources/experiments/all\n" +
  "  GET  /resources/experiments/active\n"
end

# Caps shim for the demo: in a real app, an MCP client would
# hand a Tep::AuthBearerToken JWT with the run_experiments cap
# baked in. Here, accept an X-Demo-Cap-Run header as the
# capability source so humans can drive the demo with curl.
before do
  if req.req_headers["x-demo-cap-run"].length > 0
    req.identity = Tep::Identity.new(
      "user:demo", nil, [:run_experiments])
  end
end
