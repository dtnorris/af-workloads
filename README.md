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

The [operator runbook](docs/operator-runbook.md) shows compilation and uncached
verify-only replay. The [forward workload contract](docs/AFW_FORWARD_WORKLOADS.md)
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
