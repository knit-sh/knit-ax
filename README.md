# knit-ax

A [Knit](https://github.com/knit-sh/knit) plugin that adds
[Ax](https://ax.dev) (Meta's adaptive experimentation framework) as a
Bayesian-optimization proposer. Import it to run `ax optimize` over any job or
app already registered with Knit: the plugin probes the declared parameter
domains, drives Ax's Sobol initialization and GP-EI loop, and records every
trial and the final optimum in the Knit database for full reproducibility.

## Requirements

- A `knit.sh` build that includes the **Phase-A public search-core API**
  (minimum commit `9eae5f8` on the `mdorier/knit-ax-core` branch, or any build
  from that point forward once merged to `main`). The search-core symbols the
  plugin relies on include `knit_search_loop`, `knit_search_launch`,
  `knit_search_scan`, `knit_search_parse_token`, `knit_search_resolve_fill`,
  `knit_search_resolve_target`, `knit_search_read_objective`,
  `knit_search_group_forward`, `knit_parameter_space`, `knit_parameter_type`,
  `knit_command_parameters`, `knit_command_outputs`, `knit_command_table`,
  `knit_command_run_after` and `knit_output_type`; the rest of what it uses is
  the general public `knit_*` API (registration, logging, provenance, database).
- The [knit-uv](https://github.com/knit-sh/knit-uv) plugin (imported
  automatically; manages the Ax Python environment).

## Use it

Add two lines near the top of your experiment, after `source knit.sh`:

```bash
source knit.sh
knit_import ax               # github.com/knit-sh/knit-ax
```

A run is a **campaign**: a named, resumable record stored on disk under
`campaigns/<name>/` (a sibling of `setups/` and `jobs/`, so `knit bundle` packs
it). Two commands drive it, mirroring `prepare` then `submit drain`:

- `ax prepare --campaign <name> [OPTIONS] -- <downstream>` validates the request,
  resolves the objective, builds the search space, and records the campaign —
  it runs no trial, and fails if the campaign name already exists.
- `ax optimize --campaign <name> [--trials K] [--max-inflight M] [--show-progress]`
  starts, or resumes, the ask/tell loop toward the budget. First run and every
  resume are the same call, so a campaign interrupted at walltime continues from
  its persisted state. `--trials` bounds this call; `--max-inflight` sets its
  concurrency (per call, default 1). On a terminal, `--show-progress` draws a live
  progress bar over the trial budget — two bars (this call + the whole campaign)
  when `--trials` bounds the call, a single campaign bar otherwise.
- `ax extend --campaign <name> --max-trials <N>` raises a campaign's lifetime
  budget (never below the trials already run) so `ax optimize` can search further.
- `ax list` and `ax show --campaign <name>` report progress and the current best
  from the campaign directory (no Ax process, no database).

### Optimize a job over its declared space

A trial is a real `knit submit` into the campaign's group. Any parameter that
declares a search `--domain` becomes a search dimension when you mark it `@domain`;
fixed arguments pass through. The objective is a declared output column:

```bash
knit ax prepare --campaign lr-sweep --objective val-loss --minimize \
    --max-trials 50 --seed 1 \
    -- submit --setup env -- train --epochs 20 --lr @domain --batch-size @domain
knit ax optimize --campaign lr-sweep --max-inflight 4   # drive the loop; re-run to resume
knit ax show --campaign lr-sweep                        # progress and current optimum
```

`--max-trials` is the campaign's lifetime trial budget; `ax optimize` runs up to
it (or re-run to resume where a previous call stopped). On `ax optimize`,
`--max-inflight` keeps that many trials in flight (per call, default 1) and
`--trials K` runs at most K more this call; each trial records a `call` edge back
to the campaign's `optimizations` row. Raise a reached budget to keep searching
with `knit ax extend --campaign lr-sweep --max-trials 80`. `--sobol-trials` sets
how many quasi-random trials explore before the model engages, and
`--on-failure penalize` tells the model a fixed penalty for a failed trial
instead of dropping it.

**Dimensions can span the submission and the job.** A search dimension may be a
submission option as well as a job argument — for example sweeping the node count
with `submit --nodes '{1,2,4}'` alongside `--lr @domain` on the job. Axes are
named by their command (`submit.nodes` vs `train.nodes`), so a submission option
and a same-named job option stay two distinct dimensions, each resolved against
its own command's declared domain.

**Range types are inferred from the bounds.** When the swept parameter declares
no explicit type, an integer-bounded range domain — `--domain '[0..12]'` —
becomes an **integer** range, so Ax proposes only whole numbers;
`--domain '[0.0..1.0]'` becomes a continuous (float) range. To get a continuous
range over integer-looking bounds, declare the parameter's type explicitly as
`real` in its registration — `knit_with_optional "lr:real" "0" ... --domain
'[0..12]'` — which overrides the inference; `integer` and `string` types are
honored the same way.

### Optimize app runs inside one allocation

Swap `-- submit` for `-- run` and give the launch fields. App trials share the
allocation, so they run **sequentially** (`--max-inflight` is job-mode only); the
objective is read from the app's own table:

```bash
# inside a job that holds the allocation:
knit ax prepare --campaign bench-tune --objective throughput --maximize \
    --max-trials 40 -- run --procs 8 -- bench --msg-size @domain --algo @domain
knit ax optimize --campaign bench-tune
```

## License

MIT — see [LICENSE](LICENSE).
