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
  from that point forward once merged to `main`). The required public symbols
  are: `knit_search_loop`, `knit_search_launch`, `knit_search_scan`,
  `knit_search_resolve_fill`, `knit_search_group_forward`,
  `knit_command_outputs`, `knit_command_table`.
- The [knit-uv](https://github.com/knit-sh/knit-uv) plugin (imported
  automatically; manages the Ax Python environment).

## Use it

Add two lines near the top of your experiment, after `source knit.sh`:

```bash
source knit.sh
knit_import ax               # github.com/knit-sh/knit-ax
```

Then run Bayesian optimization over a job's declared parameter space:

```bash
./experiment.sh ax optimize \
    --objective loss \
    --minimize \
    --trials 30 \
    -- submit -- train --lr @sweep --batch-size @sweep
```

## License

MIT — see [LICENSE](LICENSE).
