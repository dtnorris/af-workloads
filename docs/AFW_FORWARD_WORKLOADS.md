# Forward scoring workload contract

The executable checkout owns code, runtime policy, the model registry and
qualification files. The explicit AFW data root owns `workloads/<id>/`
(manifest, index, plan and staged binding), `workloads/.selections/<id>/`
(staged selection and publication), `build/workloads/<id>/` (case, runtime and
preflight), and `output/workloads/<id>/` (domain results and evidence). Select a
separate, existing store. Case, result and evidence paths are relative to that
store; qualification paths are relative to code. New split cases bind the
selected scorer by absolute path and commit. The scorer configuration selects
the catalog, specification and source owners; its output root must be below the
AFW data root. Absolute input paths and digests are part of replay identity.

AFW snapshots retain the `generator_commit` field. In this distribution its
`sha256:` value identifies the executable tree in an archive or Git checkout.
Hash each regular file matched by `bin/*`, `lib/**/*.rb`, `config/**/*`,
`production_backlog/**/*` and `Gemfile.lock`; sort rows by path and hash the
UTF-8 lines `<sha256><two spaces><root-relative path><LF>` together. Preserve
the tested release revision and the distribution inventory alongside its
workloads. Compilation and inspection use this same code identity.

## Compile, inspect and replay

The [operator runbook](operator-runbook.md) shows the explicit compile and
verify-only commands. `afw-inspect-workload` accepts the same workload, catalog,
IDs, dimension, capability and scorer selectors used for compilation. It reports
`fresh-build`, `reuse`, `regenerate` or `refuse`. A same-path build may
recreate a missing generated tree only if the original manifest and all bound
inputs agree. Keep original manifest bytes and consult
[frozen input identities](frozen-input-identities.md) before recovery.

## Staged authority

Pipeline owns staged admission, allocation and approval. AFW selects qualified
cases against the approved catalog, retains the immutable selection ledger and
validates the resulting workload through pipeline's actual authority callback.
Use the pipeline root, authority inputs, authority store, project state and
operation ID selected by the caller. Inspection of staged state requires the
same inputs and, for selected operations, the published selection. For
`afw-staged-selection verify`, the pipeline callback's `--root` parameter
selects AFW data and the executable path selects AFW code. The equivalent
direct flag is `--data-root`. `afw-verify-staged-workload --data-root DIR
--workload ID` revalidates the published binding by its owner.

## WLO and evidence

The [WLO v0.3 wire contract](https://github.com/dtnorris/workload-orchestrator/blob/main/contracts/wlo-execution-plan/v0.3/README.md)
defines scheduling and attempted execution. AFW emits the exact two-element argv
`["bin/afw-score-job", "build/workloads/<id>/cases/<case>.yml"]`. A separately
authorized runner selects the code root as workdir and passes the selected
store through `AFW_DATA_ROOT`. WLO owns attempt evidence and supplies placement.
See [the environment contract](scorer-environment.md) for its lifecycle.

`afw-bind-scoring-evidence` binds one job or classifies a whole workload against
WLO output. `afw-workload-evidence publish` retains an immutable manifest over
the current receipt set. `validate` checks the same AFW data root and manifest
references. Pipeline review reads the producer's evidence and owns the review
or adoption decision. A partial manifest preserves unresolved cases. A Levels
case can supply two review candidates while counting once as a case.

## Historical recovery

Replay pre-split manifests with their original generator, scorer, specification,
qualification and model bindings at their recorded storage locations. Historical
snapshots continue to use the original Git commit and qualification bytes,
including the legacy Number of Sessions policy. Preserve and restore those
inputs through the historical installation.
