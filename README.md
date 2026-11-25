# AF Workloads

AF Workloads compiles scoring intent into immutable workload manifests and WLO
execution plans. It can verify a generated case offline and bind scoring evidence
from a separately owned WLO attempt.

## Setup

Use Ruby 4.0, Bundler 4.0.17 and Git. From this distribution run
`BUNDLE_FROZEN=true bundle install`. Prepare these separately owned inputs:

- [AF Scorer](https://github.com/dtnorris/af-scorer) at
  `fdd620850b24a5b801eb68391ca3e98c22d4b28a`.
- [AF Specification](https://github.com/dtnorris/af-specification-md) at
  `394a44c2c2052ce2eeb6d28cd7647ad8a50acfcf`.
- A catalog workbook, a source registry, and the source files it names.
- An existing writable AFW data directory outside this code directory. Select it
  with `--data-root` even when the current directory is already the store.

**Compile and verify offline.** Follow the [operator runbook](docs/operator-runbook.md)
with the inputs above and an explicit scorer configuration. Compilation writes
a frozen workload and `execution-plan.json` beneath your AFW data root.
Verify-only replay prints `VERIFIED` when the case reproduces. These steps run
before model acquisition. To explore the scorer on its own, use its
[standalone offline walkthrough](https://github.com/dtnorris/af-scorer/blob/278aa45042d09366b130f169bcf940c8202acc03/README.md#offline-first-operation).

**Pulling models for scoring.** Find your model in [the model registry](config/models.yml)
and run `ollama pull <pull_model>`, including the publisher prefix when listed.
Before scoring, check the pulled model's full `digest` in Ollama's
[`GET /api/tags` response](https://docs.ollama.com/api/tags) against
`qualified_manifest_sha256`. Continue only on an exact match. If the tag moves
or disappears, search for the first 12 characters of the pinned digest to find
another tag, then verify the full digest again.

The [forward workload contract](docs/AFW_FORWARD_WORKLOADS.md)
covers relative paths, staged approval, WLO and evidence ownership. The
[EE profile](docs/MDL-01_EE_ADOPTION.md) records requirements for the first
supported offline example.

## Validate

Run `.buildkite/test.sh` from the repository after setup. Set
`AFW_TEST_SCORER_ROOT` and `AFW_TEST_SPEC_ROOT` to clean checkouts at the
pins above to run with locally available inputs. With neither set the script
obtains both pins from their public repositories. Buildkite uses the same
entry point and locked Ruby dependencies.

The MIT license and [notices](THIRD_PARTY_NOTICES.md) accompany this code.
