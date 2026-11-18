# Operator runbook

Use the pins in the [setup instructions](../README.md). Set `AFW_CODE` to this
distribution, `AFW_DATA` to the separate workload store, `AMC` to the
catalog workbook, `SCORER` to its clean checkout and `SCORER_CONFIG` to a
roots-only YAML file. Use absolute paths for externally owned inputs.

The scorer configuration includes exactly four explicit `paths` keys:
`xlsx_root`, `specification_root`, `source_root` and `output_root`.
Set `output_root` below the selected AFW data root. The optional `files`
mapping may set only `source_registry`. Scorer resolves relative root values
from its checkout and relative registry locators from its source root. The
catalog chosen by `--catalog` stays authoritative.

This example uses a synthetic workbook whose first qualified test record is
`ADV-0001`. Its source registry must resolve that row to a source document
containing the worksheet's printed page range.

```sh
mkdir -p "$AFW_DATA"
"$AFW_CODE/bin/afw-build-workload" --data-root "$AFW_DATA" \
  --workload synthetic-ee --catalog "$AMC" --ids ADV-0001 \
  --dimension 'Exploration Emphasis' --wlo-plan-version 0.3 \
  --scorer-repo "$SCORER" --scorer-config "$SCORER_CONFIG" \
  --required-context-length 131072 --require-fully-gpu-resident
"$AFW_CODE/bin/afw-score-job" --data-root "$AFW_DATA" --verify-only \
  build/workloads/synthetic-ee/cases/synthetic-ee-adv0001-ee.yml
```

Verification re-renders preflight without a prepared-source cache. A successful
replay prints `VERIFIED`. An integrity or qualification refusal exits nonzero.
Review the confirmed input identity and restore exact bytes before retrying.

For an already authorized, separately executed workload, set `WLO_OUTPUT` to
the WLO execution directory and use:

```sh
"$AFW_CODE/bin/afw-bind-scoring-evidence" --data-root "$AFW_DATA" synthetic-ee "$WLO_OUTPUT"
"$AFW_CODE/bin/afw-workload-evidence" --data-root "$AFW_DATA" publish synthetic-ee "$WLO_OUTPUT"
"$AFW_CODE/bin/afw-workload-evidence" --data-root "$AFW_DATA" validate "$MANIFEST_PATH"
```

Use the `manifest_path` returned by publication for `MANIFEST_PATH`.
The [forward workload contract](AFW_FORWARD_WORKLOADS.md) defines the
production-qualification, staged authority and evidence boundaries.
