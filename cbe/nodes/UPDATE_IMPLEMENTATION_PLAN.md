# Automated node updates on CBE.next: implementation plan

Status: draft, 2026-10-23. Owner: CBE systems engineering.

This plan adapts upstream's reboot-driven update mechanism
([nodes/update_down_node.sh](../../nodes/update_down_node.sh) and its helper scripts)
to CBE.next. It stays as close to upstream as possible.

## Scope

- **OS:** RHEL 10 only.
- **Packages:** from Red Hat Satellite (`satellite.vbc.ac.at`) content views and lifecycle environments.
  No local RPM folders.
- **Firmware:** Dell PowerEdge and Lenovo ThinkSystem servers (BMC, BIOS/UEFI, network adapters).
  NVIDIA GPU firmware is out of scope for the first version (see [Open questions](#open-questions)).
- **Slurm:** 26.05 (`Exclusive=` partition flag, which `sreboot` already uses).

## How the mechanism works (summary)

1. An admin runs `reserve_on_idle <nodes>` (shared partitions only), then `sreboot -d -r UPDATE <nodes>`.
2. Slurm reboots each node once it is idle and keeps it `DOWN`.
3. At boot, `update_down_node.sh` runs from cron. It waits for `slurmd`, reads the node's
   `State`, `NextState` and `Reason`, and updates only if the node is `DOWN` and the reboot was not
   unexpected.
4. It sources `update_software.sh` and `update_firmware.sh` from the shared `$SCRIPTDIR`, then runs
   `scontrol reboot nextstate=resume reason=Update_done <node>`.
5. On the second boot it sees `NextState=resume`, exits, and Slurm returns the node to service.

## Design principles

1. **Leave `nodes/update_down_node.sh` as upstream's file.** Send general improvements upstream.
   Keep anything upstream rejects as small, separate commits on `cbe`.
2. **Put everything specific to our site in new files under `cbe/nodes/`.** Never edit upstream's
   `nodes/update_software.sh` or `nodes/update_firmware.sh`. Upstream changes those often for DTU's
   hardware, and editing them would cause merge conflicts.
3. **Every version is decided centrally.** Packages come from a Satellite content-view version,
   and firmware from a fixed catalog or fixed files per model. A node can never pull an unreviewed version.
4. **Fail safe.** Any error leaves the node `DOWN` with a clear log entry and a mail to root.
   Nothing is retried in a loop.

## Target layout

```
nodes/update_down_node.sh          # upstream, unmodified (after phase 1 is merged)
nodes/update_software.sh           # upstream example, unused by us
nodes/update_firmware.sh           # upstream example, unused by us
cbe/nodes/update_down_node.conf    # our settings -> /etc/sysconfig/update_down_node
cbe/nodes/update_software.sh       # Satellite-based software update -> $SCRIPTDIR
cbe/nodes/update_firmware.sh       # Dell/Lenovo firmware for our models -> $SCRIPTDIR
cbe/nodes/README.md                # admin runbook
cbe/nodes/UPDATE_IMPLEMENTATION_PLAN.md   # this file
```

## Phase 1: general improvements to `update_down_node.sh` (offered upstream)

Each change is small, can be switched off, and keeps upstream's current behaviour by default.
Send them as two pull requests to `OleHolmNielsen/Slurm_tools`.

### PR 1: configuration and OS detection

**1a. Set `RPMDIR` from the detected OS version.** Replace the `el8`/`el9` if-chain in the
`CONFIGURE` section with:

```bash
# Platform-specific package directory, e.g. RPMS8, RPMS9, RPMS10.
# Set RPMDIR="" in the site config to skip local RPM packages entirely.
RPMDIR=${RPMDIR-$PACKAGEDIR/RPMS$osversion}
```

`osversion` is already calculated from `CPE_NAME` but is never used. On RHEL 10.2,
`cpe:/o:redhat:enterprise_linux:10.2` gives `10` (checked).

**1b. Optional site config file.** At the end of the `CONFIGURE` section add:

```bash
# Site-specific overrides of the variables above
SITE_CONFIG=/etc/sysconfig/update_down_node
[[ -r $SITE_CONFIG ]] && source $SITE_CONFIG
```

This lets sites set `PACKAGEDIR`, `SCRIPTDIR`, `RPMDIR`, `update_software` and `update_firmware`
without editing the script.

**1c. Makefile fix.** `slurmacct/jobstats` → `slurmacct/jobacctstats` (already fixed on `cbe` in `371719f`).

### PR 2: safety checks

**2a. Optional `UPDATE_REASON`.** Today, rebooting *any* `DOWN` node triggers an update and then
brings the node back into service, including a node an admin marked down because of a hardware fault.
Add an optional check after the "unexpectedly rebooted" check:

```bash
# CONFIGURE: If set, only update nodes whose Reason starts with this string,
# for example as set by "sreboot -d -r UPDATE <nodelist>"
UPDATE_REASON=""
...
if [[ -n "$UPDATE_REASON" && ! "$reason" =~ ^[[:space:]]*Reason=$UPDATE_REASON ]]
then
	echo "NOTICE: Reason does not start with $UPDATE_REASON, no updates will be performed" >> $LOG_FILE0
	exit 0
fi
```

**2b. Protection against reboot loops.** If `slurmd` is not running after the updates, the
script runs `shutdown -r now` while the node is still `DOWN` with no `NextState`. Every boot then
repeats the update. Add an attempt counter:

```bash
ATTEMPT_FILE=/root/update_down_node.attempts
MAX_ATTEMPTS=${MAX_ATTEMPTS:-2}
attempts=$(( $(cat $ATTEMPT_FILE 2>/dev/null || echo 0) + 1 ))
if [[ $attempts -gt $MAX_ATTEMPTS ]]
then
	echo "ERROR: $attempts update attempts, giving up. Node stays DOWN." >> $LOG_FILE0
	echo "Update of $shortname failed $MAX_ATTEMPTS times" | mail -s "Script $0" root
	exit 0
fi
echo $attempts > $ATTEMPT_FILE
```

Remove the attempt file just before the final `scontrol reboot nextstate=resume`.

**2c. Stop on helper script errors.** If the sourced helper scripts `return 1`, the script should not
continue to the final reboot. Upstream's helpers currently use `exit 1`, which already stops the
script, so this is only a documentation note in the script and README.

### PR 3 (optional): split out the firmware functions

Move `dell_update`, `lenovo_update` and `lenovo_mellanox_update` from `nodes/update_firmware.sh` into
`nodes/update_firmware_functions.sh`, and source that file from `update_firmware.sh`. We could then
source upstream's functions directly instead of copying them.

**If upstream declines** any of these, apply them as separate commits on `cbe` named
`update_down_node: <change>`. That makes them easy to spot and re-apply after each merge.

## Phase 2: our helper scripts (`cbe/nodes/`)

### `cbe/nodes/update_down_node.conf`

```bash
# CBE.next settings for update_down_node.sh, installed as /etc/sysconfig/update_down_node
PACKAGEDIR=/<TBD shared admin path>        # see open question 2
SCRIPTDIR=$PACKAGEDIR/script-dir
RPMDIR=""                                  # all packages come from Satellite
UPDATE_REASON=UPDATE                       # matches "sreboot -d -r UPDATE"
MAX_ATTEMPTS=2
```

### `cbe/nodes/update_software.sh`

Sourced by `update_down_node.sh`. Output goes to `/root/update.log`.

1. `subscription-manager refresh`. If it fails, stop with an error.
2. Log the Satellite content-view environment and enabled repositories (`subscription-manager identity`, `dnf repolist`).
3. `dnf clean all && dnf -y update`. **Stop with an error if `dnf` fails**, so the node stays `DOWN`.
4. Log versions after the update: `rpm -q kernel slurm slurm-slurmd nvidia-driver` (whichever are installed).
5. Leave out upstream's `LOCALPACKAGELIST` and the deletion of AlmaLinux/Rocky repo files. Neither applies to us.

Version control happens in Satellite: a content-view version is promoted to the compute nodes'
lifecycle environment **before** the update is triggered. All nodes updated in one round
therefore get the same package set.

### `cbe/nodes/update_firmware.sh`

Same structure as upstream: helper functions, then `dmidecode` detection, then one block per model.

- **Functions:** source `nodes/update_firmware_functions.sh` if PR 3 is merged. Otherwise copy
  `dell_update`, `lenovo_update` and `lenovo_mellanox_update` unchanged from upstream, with a comment
  naming the upstream commit they came from.
- **Tools** come from Satellite custom products, installed with `dnf` (no files on the shared folder):
  - Dell: `dell-system-update` (DSU), `srvadmin-idracadm`
  - Lenovo: `lnvgy_utl_lxcer_onecli`
- **Dell:** run DSU against a **fixed catalog** kept at `$PACKAGEDIR/Dell/catalog/<baseline>/Catalog.xml`:
  `dsu --non-interactive --apply-upgrades-only --source-type=REPOSITORY --source-location=<baseline dir>`.
  Changing the firmware baseline then means publishing a new catalog folder and pointing the config
  at it. Fall back to `dell_update <model> <file>.BIN` for single components DSU does not cover.
- **Lenovo:** `lenovo_update <model> <component> <file>` with firmware files in
  `$PACKAGEDIR/Lenovo/<model>/<component>/`, following upstream's layout.
- **Model blocks:** one `if [ "$product" == "..." ]` block per model in our inventory
  (open question 1). Unknown models log a warning and skip firmware updates. They do **not** fail,
  so a new model still gets its software updates.
- Log firmware versions before and after (`racadm getversion` / `onecli inventory`) so we can check
  the baseline was applied.

## Phase 3: deployment

| Item | Destination | How |
|---|---|---|
| `nodes/update_down_node.sh` | `/root/update_down_node.sh` on compute nodes | Ansible role (AAP), from the `cbe` branch |
| `cbe/nodes/update_down_node.conf` | `/etc/sysconfig/update_down_node` | Ansible role |
| `@reboot root /root/update_down_node.sh` | `/etc/cron.d/update_down_node` | Ansible role |
| Packages needed: `dmidecode`, `s-nail`, `NetworkManager` | compute nodes | Ansible role / Satellite host group |
| `cbe/nodes/update_software.sh`, `cbe/nodes/update_firmware.sh` | `$SCRIPTDIR` | Ansible play run on release |
| Firmware catalogs and files | `$PACKAGEDIR/{Dell,Lenovo}/...` | manual, reviewed by a second admin |

Security requirements:

- `$PACKAGEDIR` and `$SCRIPTDIR` are owned by root and writable **only** by root or the admin group,
  because their contents run as root on every node.
- The file system must be mounted at boot before cron runs. The script waits 90 s once and then gives up.
- Root mail from compute nodes must reach the CBE admin mailbox.

## Phase 4: testing

On one node per hardware model, in a dedicated test reservation:

| # | Test | Expected result |
|---|---|---|
| T1 | `sreboot -d -r UPDATE <node>` | Two reboots. Node is `IDLE` again with `Reason=Update_done` cleared. Packages match the content view. Firmware matches the baseline. |
| T2 | Normal `scontrol reboot <node>` (NextState resume) | No update. Log says `nextstate=resume`. |
| T3 | `scontrol update state=down reason=HW_fault`, then reboot | No update (stopped by `UPDATE_REASON`). Node stays `DOWN`. |
| T4 | Hard power cycle of an idle node | `Node unexpectedly rebooted`, no update. |
| T5 | `$PACKAGEDIR` not mounted | Mail to root, node stays `DOWN`. |
| T6 | `dnf` fails (e.g. Satellite unreachable) | Error in `update.log`, node stays `DOWN`, no final reboot. |
| T7 | `slurmd` disabled before the end of the update | At most `MAX_ATTEMPTS` reboots, then mail and node stays `DOWN`. |
| T8 | Shared-partition node with jobs, after `reserve_on_idle` | Backfill only starts jobs that end before the reservation. Reservation is deleted after the update. |
| T9 | Unknown hardware model | Software updated, firmware skipped with a warning. |

## Phase 5: running an update round

1. Publish and promote the new content-view version to the compute nodes' lifecycle environment.
2. If needed, publish the new Dell catalog or Lenovo firmware files and update `update_firmware.sh`.
   Deploy it to `$SCRIPTDIR`.
3. For shared partitions: `reserve_on_idle <nodes>`.
4. `sreboot -d -r UPDATE <nodes>`, in batches (e.g. one rack or ≤10 % of a partition at a time).
5. Monitor with `sinfo -R` and `sinfo -t down`. Nodes still `DOWN` with a reason other than `UPDATE`
   or `Update_done` need checking (`/root/update_down_node.log`, `/root/update.log`).

This runbook goes into `cbe/nodes/README.md`.

## Keeping in sync with upstream

- Merge `upstream/master` into `master` (fast-forward), then `master` into `cbe`, as usual.
- After each merge, run `git diff upstream/master cbe -- nodes/update_down_node.sh`. Once phase 1
  is accepted upstream it should be empty. Otherwise it should contain only our separate
  `update_down_node:` commits.
- If upstream changes the helper functions (`dell_update`, `lenovo_update`), copy the changes into
  `cbe/nodes/update_firmware.sh` (only needed if PR 3 was not accepted).

## Work breakdown

| # | Task | Depends on |
|---|---|---|
| 1 | Collect the hardware model inventory (read-only `dmidecode` via `clush`) | none |
| 2 | Decide the `PACKAGEDIR` location and the lifecycle environment | none |
| 3 | Prepare and submit upstream PR 1 and PR 2 (and optionally PR 3) | none |
| 4 | Add Satellite custom products for DSU, idracadm and OneCLI | none |
| 5 | Write `cbe/nodes/update_down_node.conf`, `update_software.sh`, `update_firmware.sh` | 1, 2 |
| 6 | Ansible role for deployment | 2, 5 |
| 7 | Tests T1–T9 | 4, 5, 6 |
| 8 | Write the `cbe/nodes/README.md` runbook | 7 |
| 9 | First production round on one partition | 8 |

## Open questions

1. **Hardware models in use** (`dmidecode -s system-product-name` per node group).
   This decides the firmware blocks.
2. **Location of `PACKAGEDIR`/`SCRIPTDIR`**: which file system is mounted on all compute nodes at boot
   and can be restricted to root/admins?
3. **Lifecycle environment** for compute nodes, and whether "promote, then reboot" fits the existing
   release process (this login node uses `CLIP_CBE/Dev/ccv-hpc`).
4. **NVIDIA B200 / HGX firmware:** add to the firmware helper later (`nvfwupd`), or keep it as a separate
   process?
5. **Mail:** does root mail from compute nodes currently reach the admin team?
