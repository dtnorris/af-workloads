# Exploration Emphasis profile

Forward Exploration Emphasis selects `ee-clean-reset-v0.5` and the
`gptoss` registry entry for `gpt-oss:20b-candidate`. The plan requires
context 131072 and full GPU residency. The runtime uses low reasoning, a
4096-token cap and temperature zero. The exact qualified digest is in
[the model registry](../config/models.yml). The qualification policy is in
[qualified_exploration_emphasis.yml](../production_backlog/qualified_exploration_emphasis.yml).

A public-method preflight establishes preparation and replay. The adapter
refuses execution of that method pending separate qualification for its Git
and method identity. Model acquisition and redistribution are outside the
scope of the registry. Recover legacy EE using the retained workflow,
`gptoss-legacy` identity and original qualification and snapshot bytes.
