# Pilot Integration Acceptance Matrix

This file defines the final gate between the research sandbox and the first live engineering pilot.

## Goal

Before any code is wired into the real app, the pilot bundle should pass a compact acceptance matrix that proves:

- the package is complete enough for the pilot shot
- the planning data is internally coherent
- the runtime adapters can render the shot without hand-fixing core data
- the mouth system overlays correctly on the chosen body angles

## Acceptance phases

### 1. Package acceptance

Required:

- approved head reference sheet
- approved body/costume sheet for the active costume
- required mouth profiles for the shot's angle family
- promotion records for all promoted references
- no blocking package regressions in diff reporting

### 2. Planning acceptance

Required:

- motion plan passes the motion linter
- mouth timing plan passes the mouth validator
- routing decision exists and matches readiness tier
- review/correction loop records are present for non-trivial generated assets

### 3. Runtime-adapter acceptance

Required:

- body adapter can render all planned keys
- mouth adapter can anchor and switch assets for each active angle
- lighting adapter can apply the shot plan to both character and background
- face and mouth readability survive the active lighting profile
- shot packet loads with stable relative paths
- export check passes for the pilot shot fixture

### 4. Lighting acceptance

Required:

- active lighting profile is present and valid
- active shot lighting plan is present and valid
- lighting review does not require regeneration
- character and background are judged to belong to the same light world
- line art, skin tone, and costume readability remain within tolerance

## Promotion rule

No asset should be promoted from candidate to long-term reference solely because it looks good. It must also satisfy the acceptance matrix entries that apply to its role in the pilot.

## Suggested workflow

1. build or refresh the pilot packet
2. run packet, routing, mouth, and diff checks
3. fill the acceptance matrix JSON
4. block integration until the matrix is fully green

See:

- `examples/sample_acceptance_matrix.json`
- `tools/acceptance_matrix_check.py`
