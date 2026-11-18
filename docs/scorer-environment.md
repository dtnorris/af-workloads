# AFW scorer environment and placement adapter

AFW owns this producer contract. The generic wire/scheduling authority is
[WLO execution plan v0.3](https://github.com/dtnorris/workload-orchestrator/blob/main/contracts/wlo-execution-plan/v0.3/README.md).
AFW's copies in `test/fixtures/afw-wlo-v0.3` are non-authoritative, byte-pinned
conformance fixtures, validated independently without WLO implementation imports.
`test/support/afw_wlo_v0_3_contract.rb` is the independent producer-side checker.

An AFW-produced scorer job has the stronger producer requirement that `env`
contains every name in this AFW-controlled namespace exactly once:

```text
AF_CATALOG_ROLE
AF_CATALOG_WORKBOOK
AF_INVESTIGATION_GUARDRAIL_PROFILE
AF_LETHALITY_GUARDRAIL_PROFILE
AF_LLM_MAX_TOKENS
AF_LLM_PROVIDER
AF_NOS_TWO_STAGE_PROFILE
AF_OPENAI_MODEL
AF_OPENAI_REASONING_EFFORT
AF_OUTPUT_DIR
AF_PROJECT_STATE
AF_PUZZLE_GUARDRAIL_PROFILE
AF_SERIOUSNESS_GUARDRAIL_PROFILE
AF_SOCIAL_INTERACTION_GUARDRAIL_PROFILE
AF_SOURCE_REGISTRY
AF_SOURCE_ROOT
AF_SPEC_ROOT
AF_XLSX_ROOT
```

Each name has either its frozen string value or `null`. This complete map
removes stale values before applying job-specific intent and prevents one job's
configuration from becoming another job's default. AFW compilation uses the
same namespace while rendering source/preflight artifacts. A scorer revision
that introduces another environment-controlled input requires AFW to extend
this producer-owned namespace before compiling a workload against that revision.

`ScorerEnvironment` reserves both `WLO_WORKER_ENDPOINT` and
`AF_OLLAMA_BASE_URL` as runtime-owned names. Workload/scorer environment input
cannot set them. Compilation removes inherited values while preparing artifacts;
frozen jobs do not carry placement authority.

For a dynamic attempt WLO supplies `WLO_WORKER_ENDPOINT`. AFW's
`ScorerAdapter` validates that HTTP(S) origin and translates it to
`AF_OLLAMA_BASE_URL` before invoking the scorer. Parent scorer endpoint values
cannot override the selected placement. Other generic commands are free to use
WLO's placement input through their own adapters.

Exact model/digest/context/full-residency requirements remain workload intent.
Current v0.3 plan policy requires literal true residency when specified; the
separate generic capability-request v0.1 contract accepts either actual boolean.
This distinction does not change either contract. AFW interprets scoring results;
WLO owns attempts, statuses and execution evidence.

Other process state remains inherited, including PATH, HOME, temporary-directory,
Ruby/Bundler and TLS settings. Provider credentials are runtime secrets rather
than frozen scoring intent; this namespace is not a generic environment scrub.

For an authorized split-workload attempt, the runner explicitly selects
`AFW_DATA_ROOT` in the launch environment and uses the public code checkout
as workdir. Keep both selectors fixed on resume. Verify-only uses the
explicit CLI `--data-root` flag.
