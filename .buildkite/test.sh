#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

scorer_pin=fdd620850b24a5b801eb68391ca3e98c22d4b28a
spec_pin=394a44c2c2052ce2eeb6d28cd7647ad8a50acfcf
scratch="$(mktemp -d "${TMPDIR:-/tmp}/afw-ci.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

if [[ -z "${AFW_TEST_SCORER_ROOT:-}" && -z "${AFW_TEST_SPEC_ROOT:-}" ]]; then
  git clone --no-checkout https://github.com/dtnorris/af-scorer.git "$scratch/scorer"
  git -C "$scratch/scorer" checkout --detach "$scorer_pin"
  git clone --no-checkout https://github.com/dtnorris/af-specification-md.git "$scratch/specification"
  git -C "$scratch/specification" checkout --detach "$spec_pin"
  export AFW_TEST_SCORER_ROOT="$scratch/scorer" AFW_TEST_SPEC_ROOT="$scratch/specification"
fi
: "${AFW_TEST_SCORER_ROOT:?select the pinned scorer}" "${AFW_TEST_SPEC_ROOT:?select the pinned specification}"
for selection in "$AFW_TEST_SCORER_ROOT" "$AFW_TEST_SPEC_ROOT"; do
  if [[ "$(git -C "$selection" rev-parse --show-toplevel)" != "$(cd "$selection" && pwd -P)" ||
        -n "$(GIT_OPTIONAL_LOCKS=0 git -C "$selection" status --porcelain)" ]]; then
    echo "Expected a clean checkout at $selection" >&2
    exit 1
  fi
done
[[ "$(git -C "$AFW_TEST_SCORER_ROOT" rev-parse HEAD)" == "$scorer_pin" ]]
[[ "$(git -C "$AFW_TEST_SPEC_ROOT" rev-parse HEAD)" == "$spec_pin" ]]

export BUNDLE_FROZEN=true
export TMPDIR="$scratch"
ruby --version
bundle --version
bundle check || bundle install
bundle exec rake test:contract
