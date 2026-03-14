# Compat Migration Plan

Status: completed in March 2026.

## Goal

Remove the `compat` build stage based on `tiredofit/alpine` and replace it with repo-owned runtime logic on top of official Alpine.

## Outcome

The migration is complete. The image now:

- builds directly from official Alpine
- uses a repo-owned entrypoint and job runner
- uses repo-owned helper functions instead of sourcing upstream `00-container`
- no longer copies runtime files from a `compat` build stage
- no longer depends on upstream `/init`, `/command/with-contenv`, or `/etc/services.available`

## Implemented Runtime

Current runtime entry points:

- `/usr/local/bin/dbbackup-entrypoint`
- `/usr/local/bin/dbbackup-job`
- `/assets/functions/01-dbbackup-compat`

Current manual execution paths:

- `backup-now`
- `backup01-now`
- `/usr/local/bin/dbbackup-job 01 now`

## Validation

The compat-free image was validated locally with Docker smoke coverage for:

- PostgreSQL 18 backup and restore
- MySQL 8 backup and restore
- Redis backup
- MongoDB backup
- SQLite backup
- S3/MinIO upload

No zabbix references appeared in runtime logs during the smoke run.

The migration must preserve:

- startup and shutdown behavior
- scheduled and manual backup execution
- current environment-variable compatibility
- restore workflow
- multi-job orchestration

## Current State

The current image is not yet an independent Alpine image. It still imports the runtime framework from:

`FROM docker.io/tiredofit/${DISTRO}:${DISTRO_VARIANT} AS compat`

The final image copies these runtime pieces from that compatibility stage:

- `/init`
- `/assets`
- `/command`
- `/package`
- `/etc/cont-init.d`
- `/etc/cont-finish.d`
- `/etc/s6-overlay`
- `/etc/services`
- `/etc/services.available`
- `/etc/services.d`
- `/usr/local/bin`

## Dependency Surface

The repo-owned scripts currently depend on the compatibility layer in four major ways.

### 1. Shell wrapper and init model

These scripts use `#!/command/with-contenv bash` and assume the old init layout:

- [install/etc/cont-init.d/10-db-backup](c:\Users\Abdulla\IDE\docker-db-backup\install\etc\cont-init.d\10-db-backup)
- [install/assets/functions/10-db-backup](c:\Users\Abdulla\IDE\docker-db-backup\install\assets\functions\10-db-backup)
- [install/assets/dbbackup/template-dbbackup/run](c:\Users\Abdulla\IDE\docker-db-backup\install\assets\dbbackup\template-dbbackup\run)
- [install/usr/local/bin/restore](c:\Users\Abdulla\IDE\docker-db-backup\install\usr\local\bin\restore)

This means the image expects:

- `/init`
- `/command/with-contenv`
- `s6` service directories and conventions

### 2. Helper function library

Repo code directly sources `/assets/functions/00-container` and uses functions that do not exist in this repository.

Known examples:

- `prepare_service`
- `liftoff`
- `create_schedulers`
- `check_container_initialized`
- `check_service_initialized`
- `package`
- `transform_file_var`
- `var_true`
- `var_false`
- `print_debug`
- `print_info`
- `print_notice`
- `print_warn`
- `print_error`
- `silent`
- `clone_git_repo`

Without replacing `00-container`, the repo cannot stand on its own.

### 3. Service supervision and scheduling

The runtime dynamically creates scheduler services under `/etc/services.available` and controls them with `s6-svc`.

Examples:

- per-backup run script template: [install/assets/dbbackup/template-dbbackup/run](c:\Users\Abdulla\IDE\docker-db-backup\install\assets\dbbackup\template-dbbackup\run)
- scheduler creation and manual-mode adjustments: [install/assets/functions/10-db-backup](c:\Users\Abdulla\IDE\docker-db-backup\install\assets\functions\10-db-backup)

This is a hard dependency on the existing service model.

### 4. Runtime helper binaries and scripts

Some helper commands are inherited indirectly from the compatibility image through copied paths under `/usr/local/bin`, `/command`, and `/package`.

That means behavior can drift if upstream changes, and the repo does not fully describe its own runtime.

## Recommended Strategy

Use a staged migration. Do not attempt a one-shot removal of `compat`.

### Phase 0: Freeze and observe

Objective:

- document the current runtime contract
- add tests around the behavior that must not break

Deliverables:

- this migration plan
- a compat audit checklist
- test coverage for startup, scheduling, env inheritance, and manual invocation

Exit criteria:

- baseline test matrix is stable on current architecture

### Phase 1: Vendor the missing framework contract

Objective:

- make the repository own the interfaces it currently imports from `tiredofit`

Approach:

- create a repo-owned compatibility layer under `install/assets/functions` and `install/usr/local/bin`
- explicitly provide wrappers or replacements for the subset of `00-container` functions that this project actually uses
- stop depending on upstream `/assets/functions/00-container` for project-specific behavior

Recommended first targets:

- boolean helpers: `var_true`, `var_false`
- logging helpers: `print_*`
- shell helpers: `silent`, `transform_file_var`
- package/build helpers used during Docker build: `package`, `clone_git_repo`

Exit criteria:

- Docker build no longer needs `source /assets/functions/00-container` for project-specific logic
- repo scripts source repo-owned helpers first

### Phase 2: Replace the init entrypoint contract

Objective:

- remove dependence on upstream `/init` and `/command/with-contenv`

Approach options:

- Option A: adopt upstream `s6-overlay` directly and wire repo-owned init scripts to it
- Option B: replace `s6` with a repo-owned shell entrypoint plus one scheduler loop

Recommendation:

- use Option A first
- it preserves behavior with less application rewrite

Required replacements:

- repo-owned entrypoint
- repo-owned environment initialization
- repo-owned service bootstrapping

Exit criteria:

- `ENTRYPOINT ["/init"]` from upstream is removed
- shebangs no longer require `/command/with-contenv`

### Phase 3: Simplify scheduling architecture

Objective:

- reduce service fan-out and dynamic service generation

Current issue:

- one backup job currently maps to generated service definitions and `s6-svc` control flow

Preferred future shape:

- a single supervisor process starts one scheduler loop
- scheduler loop dispatches jobs internally
- manual mode and scheduled mode share the same execution path

Benefits:

- easier tests
- fewer moving parts
- no dynamic service tree mutation
- easier distroless or smaller-image work later

Exit criteria:

- no new directories written under `/etc/services.available` at runtime
- manual backup path and scheduled backup path use the same command

### Phase 4: Remove `compat`

Objective:

- delete the compatibility stage entirely

Required before removal:

- no copied files from `compat` remain necessary at runtime
- helper functions are repo-owned
- init and supervision are repo-owned
- test matrix passes without inherited service files

Final Dockerfile target:

- one official base image
- explicit package install list
- explicit repo-owned entrypoint and scripts

## Execution Order

Recommended order of work:

1. Introduce repo-owned helper library for reused shell functions.
2. Update repo scripts to source the new helper library before any legacy fallback.
3. Move build-time helpers (`package`, `clone_git_repo`) into repo-owned build scripts.
4. Replace `with-contenv` shebang usage with standard shell entrypoints.
5. Introduce repo-owned init and service bootstrapping.
6. Collapse manual and scheduled execution into one internal code path.
7. Remove remaining `COPY --from=compat ...` lines one group at a time.
8. Delete the `compat` stage.

## Test Gates

Every phase should pass these checks before proceeding:

- PostgreSQL backup and restore
- MySQL backup and restore
- Redis backup
- MongoDB backup
- SQLite backup
- S3/MinIO upload
- timezone handling
- default env inheritance
- per-job env override precedence
- concurrency behavior
- scheduled mode
- manual mode
- restore helper script

## Risks

Highest-risk areas:

- shebang and environment-loading differences after removing `with-contenv`
- subtle logging and boolean parsing behavior from `00-container`
- dynamic `s6` service generation for manual and scheduled jobs
- env compatibility regressions from legacy variable handling
- startup sequencing issues between init, scheduler creation, and backup execution

## First Implementation Slice

The safest first code slice is:

- add a repo-owned helper file that implements the shell utilities this project uses most
- update repo scripts to source that helper file before relying on legacy imports
- keep `compat` in place as fallback during the transition

That gives a testable intermediate state:

- current behavior remains available
- project-owned runtime logic starts replacing upstream assumptions
- later removal of `compat` becomes mechanical instead of architectural guesswork

## Non-Goals For The First Slice

Do not attempt these in the first migration step:

- remove `s6`
- rewrite scheduling logic
- change backup naming again
- change supported environment variables
- change image variants or package matrix at the same time

## Approval Gate

Do not push migration work until:

- the helper-layer replacement is implemented
- startup and smoke tests pass locally
- manual and scheduled modes are both verified
- the remaining compat dependencies are re-audited
