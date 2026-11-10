slurm_tool
==========

Easy to use wrapper for slurm read-only commands

Origin and license
------------------

Imported with `git subtree` from https://github.com/jabl/slurm_tool
(upstream commit 0875d96, version 1.0.1, originally written at Aalto University).
This subdirectory is licensed under the GNU General Public License v2.0, see [LICENSE](LICENSE),
unlike the rest of this repository (GPLv3).

To pull later upstream changes:
```
git subtree pull --prefix=slurm_tool https://github.com/jabl/slurm_tool.git master --squash
```

Changes for CBE.next
--------------------

* `slurm top` and `slurm cpus jobs|queue` take memory and GPUs from the job TRES (`squeue -O tres-alloc`).
  Upstream assumed `%m` was plain MB, which gives wrong totals with current Slurm (`8G`).
* `slurm top` and `slurm cpus jobs|queue` show full GPUs and MIG slices in separate columns,
  split by GPU type (MIG types carry a profile such as `_1g.23gb`). Pending jobs that request
  a GPU without a type count as full GPUs.
* `slurm qos` shows GPU limits; these are set as plain `gres/gpu` and do not distinguish MIG.
* `slurm qos` reads `GrpTRES` and `MaxTRESPU` instead of `GrpCPUs` and `MaxCPUsPerUser`.
* `slurm qos <user>` asks `sacctmgr` for the `QOS` field by name, as its position changed.
* `slurm nodes` shows the node GRES, wide enough for the MIG GRES names.
* The `makeversion` script is removed; the version is fixed as `1.0.1-cbe`.

Installation
------------

`make install` in the top directory links `slurm` into `$(PREFIX)/bin`.
Bash completion of the subcommands is in [bash-completion](../bash-completion/).

Usage
-----

Run `slurm` without arguments for the list of subcommands, for example:
```
slurm q                 # own jobs
slurm top               # users with running jobs: jobs, cores, GPUs, memory
slurm cpus queue        # cores, GPUs and memory requested by pending jobs per partition
slurm h 2days           # own jobs finished in the last 2 days
slurm watch q           # refresh every 15 seconds
```

Output formats can be overridden in `~/.config/slurmvars` (or `$XDG_CONFIG_HOME/slurmvars`).
