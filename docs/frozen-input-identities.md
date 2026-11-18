# Frozen input identities

New forward (WLO v0.3/v0.4) compilations record
`afw-frozen-input-identities/v0.1`. This is an additive AFW runtime envelope,
not a WLO wire change or a new method qualification. Case and snapshot
`afw-workload/v0.1` remain compatible with existing receipt consumers.

The envelope is selected by `afw_frozen_input_contract` in both the snapshot
and runtime. The runtime bytes are bound by the case and frozen case index.
For these cases `frozen_input_identities` is mandatory: an exact mapping with
`contract_version`, `source_file`, `source_registry`, `ontology`,
`assessment_spec`, and `model_registry`. Each input has only an absolute
`path` and lowercase SHA-256 `sha256`. Missing entries, nulls, arrays, wrong
types, unsupported versions, extra fields and changed bytes refuse verification.
Deleting case metadata cannot remove the requirement carried by the bound runtime.
The runtime also carries `afw_frozen_input_identities_sha256`, a canonical digest
of the entire identity mapping. Rewriting a case binding to match changed inputs
therefore conflicts with the frozen runtime/index hash chain. The frozen validator
resolves current inputs through Config to independently reproduce this digest.

AFSU Config, Catalog and SourceResolver resolve operative source/spec paths in
a subprocess with the same frozen environment used by preparation/replay.
AFW captures source/registry bytes before shared preparation and compares the
actual owner prepared-source bindings. It checks those bindings again before
preflight. Both spec files are captured before preflight and checked afterwards;
resolved paths are also checked again. A mutation between capture, preparation
and rendering refuses materialization. Metadata contains no source or spec text.

The model parser consumes the same registry bytes whose hash is recorded.
Replay first verifies immutable registry identity, then checks the current
selected alias, model and exact digest against the case and CurrentRuntimePolicy.
This is separate from frozen qualification-file identity and from actual model,
runtime or method qualification. Rendering a preflight establishes none of the
latter. Scorer HEAD/protected paths, staged authority, runtime/qualification/
preflight/catalog hashes and uncached rendered equality remain enforced.

For the selected public method, SC-03's existing preflight `run_metadata.method`
records repository `dtnorris/af-specification-md`, revision
`394a44c2c2052ce2eeb6d28cd7647ad8a50acfcf`, the full inventory/required-file
hashes and effective canonical or retained loader/profile. AFW binds that entire
preflight alongside the actual scorer HEAD, runtime, source/model registry and
prompt/schema hashes. No new workload identity envelope is needed. The scorer's
`SelectedMethod` owns required-document validation; only AFAO and AssessmentSpec
are operative scoring documents. Upstream catalog/ABDS rules remain upstream.

Staged selection accepts prepared-source v0.2 only after the pinned producer's
real replay validator re-resolves its complete content, policy and target context.
The content-free ledger binds the exact prepared payload and target-eligibility
snapshot hashes as well as the existing authority/file/policy bindings. A v0.1
payload must come from a genuine v0.1 producer; its original ledger shape and
disabled-clamp nil/default-gap equivalence remain supported. A v0.2 producer's
payload cannot be relabeled v0.1 to bypass context validation.

Public preparation and `afw-score-job --verify-only` do not authorize production
execution. The adapter refuses execution of a public method with
`public method execution requires separate qualification`; retained qualification
files are not approval of the new Git identity. A separately reviewed qualification
policy and domain qualification are required before enabling that execution path.
Do not relabel historical profiles, update old approvals or treat equal text as
qualification. Configured historical cases retain their existing execution checks.

Existing manifests without the envelope retain their original checks and weaker
guarantees. Reconstruction reads their existing snapshot and does not relabel
them. New non-forward legacy v0.1/v0.2 plans likewise retain their existing
contract. Unsupported or malformed explicit envelopes refuse; they never fall
through to legacy mode. Removing a snapshot marker from a new manifest cannot
reconstruct its frozen runtime hashes. Historical manifests are not upgraded.

The identities are integrity checks against frozen metadata, not signatures or
authorization to rewrite that metadata and its hash chain. Verification detects
observed stable drift and brackets preparation/rendering; it does not provide
filesystem locking against an adversary changing and restoring bytes between
reads. Runtime execution still requires the separately qualified model and
placement. AFW receipts remain proposed evidence; partial publication and a zero
exit never mean ACCEPT.

