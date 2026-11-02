# Toolkit command reference

> Generated from the argc JSON spec. For destructive-operation safeguards and recovery, follow the [deployment runbook](deployment.md), not this command list.

## `bash toolkit/deploy.sh`

Shared deployment toolkit; only install erases a disk.

### `bash toolkit/deploy.sh discover`

Create a private discovery record for one whole disk

| Argument | Required | Description |
| --- | --- | --- |
| `TARGET` | yes | Root SSH target |
| `DISK` | yes | Whole /dev disk |
| `RECORD` | yes | New private discovery record |

### `bash toolkit/deploy.sh preflight`

Re-probe and compare the target with its discovery record

| Argument | Required | Description |
| --- | --- | --- |
| `RECORD` | yes | Private discovery record |

### `bash toolkit/deploy.sh install`

Build and install an exact pushed revision; erases the selected disk

| Argument | Required | Description |
| --- | --- | --- |
| `RECORD` | yes | Discovery record |
| `REPO` | yes | Clean consumer checkout |
| `REV` | yes | Full pushed commit |
| `MACHINE` | yes | Credential-free private inputs |
| `HOST` | yes | NixOS output |
| `BRANCH` | yes | Pushed branch |
| `RECEIPT` | yes | New off-host receipt |
| `GENERATOR` | no | Report generator, or - |
| `RECOVERY` | no | Recovery tree, or - |
| `PRE_ERASE` | no | Pre-erase check, or - |

### `bash toolkit/deploy.sh bootstrap`

Bootstrap the exact installed revision without erasing disks

| Argument | Required | Description |
| --- | --- | --- |
| `RECEIPT` | yes | Off-host receipt |
| `REPO` | yes | Consumer checkout |
| `MACHINE` | yes | Original private inputs |
| `CHECKOUT` | yes | Remote checkout |
| `REMOTE_MACHINE` | yes | Remote machine directory |
| `STATE` | yes | Remote root-only state |

### `bash toolkit/deploy.sh adopt`

Adopt a verified legacy host without reinstalling

| Argument | Required | Description |
| --- | --- | --- |
| `EVIDENCE` | yes | Operator-verified evidence |
| `REPO` | yes | Consumer checkout |
| `MACHINE` | yes | Original private inputs |
| `HOST` | yes | NixOS output |
| `CHECKOUT` | yes | Remote checkout |
| `REMOTE_MACHINE` | yes | Remote machine directory |
| `STATE` | yes | Remote state |

### `bash toolkit/deploy.sh transition`

Run a reviewed non-destructive candidate transition

| Argument | Required | Description |
| --- | --- | --- |
| `RECEIPT` | yes | Install receipt |
| `TARGET` | yes | Root SSH target |
| `CHECKOUT` | yes | Remote checkout |
| `BRANCH` | yes | Candidate branch |
| `NEW_MACHINE` | yes | Reviewed private machine input |
| `REMOTE_MACHINE` | yes | Remote machine directory |
| `HOST` | yes | NixOS output |
| `STATE` | yes | Remote state |

### `bash toolkit/deploy.sh poll`

Poll the root-owned selector for a new revision (target-side)

| Argument | Required | Description |
| --- | --- | --- |
| `REPO` | yes | Target checkout |
| `MACHINE` | yes | Target private machine input |
| `HOST` | yes | NixOS output |
| `STATE` | yes | Root-only state |

### `bash toolkit/deploy.sh deploy`

Switch to an explicitly selected revision (target-side)

| Argument | Required | Description |
| --- | --- | --- |
| `REPO` | yes | Target checkout |
| `REF` | yes | commit:SHA or branch:NAME |
| `MACHINE` | yes | Target private machine input |
| `HOST` | yes | NixOS output |
| `STATE` | yes | Root-only state |

### `bash toolkit/deploy.sh migrate`

Pin an existing installed revision in root-owned state

| Argument | Required | Description |
| --- | --- | --- |
| `STATE` | yes | Root-only state |
| `REF` | yes | Installed commit pin |

### `bash toolkit/deploy.sh manifest`

Operate on a private off-host JSON manifest

#### `bash toolkit/deploy.sh manifest plan`

Review target, whole disk and exact pushed tip without installing

| Argument | Required | Description |
| --- | --- | --- |
| `FILE` | yes | Mode-600 private manifest |

#### `bash toolkit/deploy.sh manifest install`

Build and install from a reviewed manifest; erases the selected disk

| Argument | Required | Description |
| --- | --- | --- |
| `FILE` | yes | Mode-600 private manifest |

#### `bash toolkit/deploy.sh manifest bootstrap`

Resume non-destructive bootstrap from a private manifest

| Argument | Required | Description |
| --- | --- | --- |
| `FILE` | yes | Mode-600 private manifest |

#### `bash toolkit/deploy.sh manifest transition`

Apply a reviewed non-destructive transition

| Argument | Required | Description |
| --- | --- | --- |
| `FILE` | yes | Mode-600 private manifest |

### `bash toolkit/deploy.sh prepare-transition`

Internal: prepare a reviewed transition upload (target-side)

| Argument | Required | Description |
| --- | --- | --- |
| `REPO` | yes | Remote checkout |
| `MACHINE` | yes | Remote machine |
| `STATE` | yes | Remote state |
| `REV` | yes | Installed revision |
| `SHA` | yes | Installed machine hash |

### `bash toolkit/deploy.sh apply-transition`

Internal: apply a reviewed candidate transition (target-side)

| Argument | Required | Description |
| --- | --- | --- |
| `REPO` | yes | Remote checkout |
| `BRANCH` | yes | Reviewed branch |
| `MACHINE` | yes | Remote machine |
| `HOST` | yes | NixOS output |
| `STATE` | yes | Root-only state |
| `REVIEWED` | yes | Reviewed machine input |
| `REV` | yes | Installed revision |
| `SHA` | yes | Installed machine hash |

## `bash toolkit/audit-app.sh`

Read-only GitHub App installation and scoped-token permission audit.

| Argument | Required | Description |
| --- | --- | --- |
| `APP` | yes | Numeric GitHub App ID |
| `KEY` | yes | Private App signing key path (never contents) |
| `POLICY` | yes | Expected permissions JSON |
| `REPO` | yes | Calling repository |

## `bash toolkit/bootstrap-remote.sh`

Internal root-only bootstrap protocol. Never installs disks.

### `bash toolkit/bootstrap-remote.sh prepare`

Prepare a retryable incoming upload (internal, target-side)

| Argument | Required | Description |
| --- | --- | --- |
| `URL` | yes | Consumer Git origin |
| `REV` | yes | Installed commit |
| `REPO` | yes | Target checkout |
| `MACHINE` | yes | Private machine directory |
| `STATE` | yes | Root-only state |
| `BRANCH` | yes | Installed branch |

### `bash toolkit/bootstrap-remote.sh finish`

Verify and commit a completed upload (internal, target-side)

| Argument | Required | Description |
| --- | --- | --- |
| `URL` | yes | Consumer Git origin |
| `REV` | yes | Installed commit |
| `REPO` | yes | Target checkout |
| `MACHINE` | yes | Private machine directory |
| `STATE` | yes | Root-only state |
| `BRANCH` | yes | Installed branch |

## `bash toolkit/new-operator-manifest.sh`

Interactively author a private off-host operator manifest; never installs.

| Argument | Required | Description |
| --- | --- | --- |
| `OUTPUT` | yes | New absolute private JSON path |
