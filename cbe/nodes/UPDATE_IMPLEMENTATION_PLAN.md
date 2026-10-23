# Automated node updates on CBE.next: implementation plan

Status: draft, revised 2026-10-23. Owner: CBE systems engineering.
Tracking issue: [CLIP-HPC/clip-cbe-cluster#89](https://github.com/CLIP-HPC/clip-cbe-cluster/issues/89).

## Decision

We build our own implementation for CBE.next and **do not reuse** upstream's
[nodes/update_down_node.sh](../../nodes/update_down_node.sh) or its helper scripts. Upstream remains the
model for the overall idea: a reboot triggered through Slurm leaves the node `DOWN`, and an update runs
at boot before the node goes back into service. The code is written for our environment only:

- **OS:** RHEL 10 only.
- **Packages:** Red Hat Satellite (`satellite.vbc.ac.at`) content views and lifecycle environments. No local RPM folders.
- **Firmware:** Dell PowerEdge (DSU) and Lenovo ThinkSystem (OneCLI). NVIDIA GPU/HGX firmware is out of
  scope for the first version (see [Open questions](#open-questions)).
- **Slurm:** 26.05.
- **Deployment:** an Ansible role in [CLIP-HPC/clip-cbe-cluster](https://github.com/CLIP-HPC/clip-cbe-cluster).

The code lives in clip-cbe-cluster, not in Slurm_tools. We stay on Slurm_tools' generic admin commands
`sreboot` and `reserve_on_idle` to trigger updates, because they are only wrappers around `scontrol`.
No upstream pull requests are needed.

## What we keep from upstream, and what we change

| Upstream (`update_down_node.sh`) | CBE.next |
|---|---|
| `@reboot` cron job | systemd oneshot unit `cbe-node-update.service`, ordered after `slurmd`, the network and the mounts it needs |
| Updates every `DOWN` node that did not reboot unexpectedly | Updates only when `Reason` is exactly `UPDATE` or starts with `UPDATE:`. A node set `DOWN` for a hardware fault is never updated. |
| Parses `scontrol show node` with `grep`/`awk` | Parses `scontrol --json show node` with `jq` |
| At boot, copies helper scripts from a shared folder and runs them as root | Script deployed by Ansible from git. Only firmware repositories are on shared storage. |
| `RPMDIR` per EL version, local RPM folders | `dnf distro-sync` against the Satellite content view assigned to the node |
| One firmware block per hardware model with individual files | Branches on the manufacturer only. DSU/OneCLI pick matching packages from a fixed baseline repository. |
| Errors: log file, sometimes mail. A missing `slurmd` can cause reboot loops. | Errors set `Reason="UPDATE_FAILED: <step>"`. The node stays `DOWN`, is visible in `sinfo -R` and is never retried automatically. |
| Logs only in `/root/*.log` | journald (`journalctl -u cbe-node-update`), shipped to Loki like other system logs |

## How it works

1. **Trigger.** An admin promotes the content view (and firmware baseline, if any), then runs:
   - for shared partitions: `reserve_on_idle <nodes>`
   - `sreboot -d -r UPDATE <nodes>` (equivalent to `scontrol reboot ASAP nextstate=down reason=UPDATE <nodes>`).
     A free-text suffix is allowed, e.g. `-r "UPDATE: CV 14.0"`.
2. **First boot.** Slurm reboots each node once it is idle and keeps it `DOWN` with `Reason=UPDATE`.
   `cbe-node-update.service` starts after `slurmd` and checks the node with `scontrol --json show node`:
   - Not `DOWN`, or `Reason` does not match `^UPDATE(:|$)` → log "nothing to do", exit 0.
   - Matches → set `Reason="UPDATE: running"` and continue.
3. **Software update** (see below). On failure: `Reason="UPDATE_FAILED: software"`, exit.
4. **Firmware update** (see below). On failure: `Reason="UPDATE_FAILED: firmware"`, exit.
5. **Checks** that the node can run jobs after the next boot: the kernel module for the NVIDIA driver
   exists for the new default kernel (GPU nodes), and `slurmd` is running. On failure:
   `Reason="UPDATE_FAILED: checks"`, exit.
6. **Finish.** Delete the reservation `update-<node>` if it exists (created by `reserve_on_idle`), then
   `scontrol reboot nextstate=resume reason=UPDATE_DONE <node>`.
7. **Second boot.** The service sees `Reason=UPDATE_DONE`, which does not match, and exits. Slurm returns
   the node to service.

Because every failure changes `Reason` to `UPDATE_FAILED: ...`, which does not match the trigger, a node
that failed is never updated again on its own and cannot get into a reboot loop. A node that loses power
during an update still has `Reason="UPDATE: running"`, so the next boot runs the update again. Both
updates are safe to repeat. An attempt counter in `/var/lib/cbe-node-update/` (max 2) is a second safety net.

## Components

All in clip-cbe-cluster, as a new role `ansible/roles/node_update` (name to be confirmed).

### `cbe-node-update` (script, `/usr/local/sbin/cbe-node-update`)

Bash with `set -euo pipefail`, one function per step, and a trap that sets `UPDATE_FAILED: <step>` on
any error. It reads its settings from `/etc/sysconfig/cbe-node-update`. The Slurm node name is
`hostname -s` unless `NODENAME` is set in the config. `--dry-run` runs the checks and lists pending
updates (`dnf check-update`, `dsu --preview`, `onecli update compare`) without changing anything.

### Software update

1. `subscription-manager refresh` and log the content view and lifecycle environment (`subscription-manager identity`).
2. `dnf clean all && dnf -y distro-sync`. `distro-sync` makes the node match the content view exactly,
   so promoting an older content-view version also rolls nodes back.
3. Log the versions afterwards: `kernel`, `slurm*`, NVIDIA driver and kmod packages, `rdma-core`.

Version control is in Satellite: a content-view version is promoted to the compute nodes' lifecycle
environment **before** the update round, so all nodes in a round get the same packages.

### Firmware update

- **Detection:** `dmidecode -s system-manufacturer` → Dell, Lenovo, or other.
- **Baseline:** `FIRMWARE_BASELINE=<name>` in the config. Each vendor has one folder per baseline in
  `$FIRMWARE_REPO/{Dell,Lenovo}/<baseline>/`. Changing the baseline means publishing a new folder and
  changing that variable through Ansible. Old folders stay for rollback.
- **Dell:** `dsu --non-interactive --apply-upgrades-only --source-type=REPOSITORY --source-location=<baseline dir>`
  (the folder has a `Catalog.xml` from Dell Repository Manager).
- **Lenovo:** `onecli update flash --dir <baseline dir> --scope latest --nolog` (folder filled with
  `onecli update acquire`). Exact options are confirmed in testing.
- **Other manufacturers:** log a warning and skip firmware. This is not an error.
- **Exit codes:** the documented "nothing to update" and "reboot required" codes of DSU and OneCLI count
  as success. Any other code is a failure.
- Log firmware versions before and after (`racadm getversion` / `onecli inventory`).
- No per-model logic. A model-specific step is added only if we find a component DSU/OneCLI does not cover.

### systemd unit `cbe-node-update.service`

```ini
[Unit]
Description=Update this node if Slurm rebooted it for an update
Wants=network-online.target slurmd.service
After=network-online.target slurmd.service remote-fs.target
RequiresMountsFor=<FIRMWARE_REPO>

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/cbe-node-update
TimeoutStartSec=2h

[Install]
WantedBy=multi-user.target
```

### Config `/etc/sysconfig/cbe-node-update` (Ansible template)

```bash
FIRMWARE_REPO=/<TBD shared admin path>     # open question 2
FIRMWARE_BASELINE=<TBD, e.g. 2026-11>
MAX_ATTEMPTS=2
```

### Ansible role tasks

- Install the script, config, systemd unit; enable the unit.
- Install `jq`, `dmidecode`; vendor tools by `ansible_system_vendor` from Satellite custom products:
  Dell `dell-system-update` + `srvadmin-idracadm`, Lenovo `lnvgy_utl_lxcer_onecli`.
- Bump the pinned Slurm_tools version on `control` (currently `v1.0.1` in `ansible/slurm.yml`) and run
  `make install_admintools`, so `sreboot` and `reserve_on_idle` are on the admin `PATH`.
- Lint with the repo's existing `ansible-lint`/pre-commit setup. Add a goss check that the unit is enabled.

### Security

- The firmware repository is on storage writable **only** by root/admins, because its contents are
  flashed onto every node. New baselines are reviewed by a second admin.
- The script itself is not loaded from shared storage at boot. It only changes through git and Ansible.

## Testing

On one node per hardware model, in a dedicated test reservation:

| # | Test | Expected result |
|---|---|---|
| T1 | `sreboot -d -r UPDATE <node>` | Two reboots. Node `IDLE`, packages match the content view, firmware matches the baseline. |
| T2 | `scontrol reboot <node>` (normal reboot) | No update. Log says nothing to do. |
| T3 | `scontrol update state=down reason=HW_fault`, then reboot | No update. Node stays `DOWN` with `HW_fault`. |
| T4 | Hard power cycle of an idle node | No update (`Node unexpectedly rebooted` does not match). |
| T5 | Firmware repository not mounted | Unit waits for the mount, then fails. `UPDATE_FAILED: firmware`, node stays `DOWN`. |
| T6 | Satellite unreachable / `dnf` fails | `UPDATE_FAILED: software`, node stays `DOWN`, no reboot. |
| T7 | Power loss during the update | Next boot runs the update again (`UPDATE: running`). After `MAX_ATTEMPTS`, `UPDATE_FAILED: attempts`. |
| T8 | Shared-partition node with jobs, after `reserve_on_idle` | Backfill only starts jobs that end before the reservation. Reservation deleted after the update. |
| T9 | Unknown manufacturer | Software updated, firmware skipped with a warning, node returns to service. |
| T10 | GPU node, kernel update without matching NVIDIA kmod in the content view | `UPDATE_FAILED: checks`, node stays `DOWN`. |
| T11 | Older content view promoted (rollback) | `distro-sync` downgrades packages to the content view. |
| T12 | `--dry-run` on a node in service | Lists pending updates, changes nothing, does not touch the Slurm state. |

## Running an update round

1. Publish and promote the new content-view version to the compute nodes' lifecycle environment.
2. If needed, publish a new firmware baseline and set `FIRMWARE_BASELINE` in the inventory. Run the role.
3. Optional: `cbe-node-update --dry-run` on a node in service to preview the changes.
4. For shared partitions: `reserve_on_idle <nodes>`.
5. `sreboot -d -r "UPDATE: <CV version>" <nodes>`, in batches (e.g. one rack or ≤10 % of a partition).
6. Monitor `sinfo -R`. `UPDATE: running` = in progress. `UPDATE_FAILED: <step>` = check with
   `journalctl -u cbe-node-update -b` on the node, fix, then resume or retrigger.

This runbook goes into clip-cbe-cluster `docs/runbooks/`.

## Work breakdown

| # | Task | Depends on |
|---|---|---|
| 1 | Hardware model inventory (read-only `dmidecode` via `clush`), for building the firmware repositories and choosing test nodes | none |
| 2 | Decide the firmware repository location and the compute nodes' lifecycle environment | none |
| 3 | Add Satellite custom products for DSU, idracadm and OneCLI | none |
| 4 | Write `cbe-node-update`, systemd unit and config template | none |
| 5 | Ansible role `node_update` in clip-cbe-cluster, plus Slurm_tools version bump on `control` | 2, 3, 4 |
| 6 | Build the first Dell and Lenovo firmware baselines | 1, 2 |
| 7 | Tests T1–T12 | 5, 6 |
| 8 | Runbook in clip-cbe-cluster `docs/runbooks/` | 7 |
| 9 | First production round on one partition | 8 |

## Open questions

1. **Hardware models in use.** The code does not depend on them. They decide what the firmware
   repositories must contain and which nodes we test on.
2. **Firmware repository location:** a file system mounted on all compute nodes at boot and writable
   only by root/admins, or an internal HTTP server (DSU supports HTTP repositories; check OneCLI).
3. **Lifecycle environment** for compute nodes, and whether "promote, then reboot" fits the existing
   release process (this login node uses `CLIP_CBE/Dev/ccv-hpc`).
4. **NVIDIA B200 / HGX firmware:** add to the script later (`nvfwupd`), or keep it as a separate process?
5. **Nodes built from images:** compute nodes are built with Packer. Do we update them in place with
   `dnf`, or should a new image plus reprovisioning be the main path, with this mechanism only
   for firmware and urgent fixes?
6. **Where the plan lives:** move this document to clip-cbe-cluster `docs/` (e.g. as an ADR) now that
   the code lives there.
