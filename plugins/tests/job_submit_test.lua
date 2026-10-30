--[[
Tests for ../job_submit.lua with a stubbed slurm table.
Run from the plugins directory: lua tests/job_submit_test.lua
--]]

slurm = {
	SUCCESS = 0,
	ERROR = -1,
	NO_VAL = 4294967294,
	NO_VAL16 = 65534,
	ESLURM_INVALID_PARTITION_NAME = 2000,
	ESLURM_INVALID_NODE_COUNT = 2006,
	ESLURM_PATHNAME_TOO_LONG = 2012,
	ESLURM_BAD_TASK_COUNT = 2025,
	ESLURM_INVALID_TASK_MEMORY = 2044,
	ESLURM_INVALID_GRES = 2072,
	ESLURM_USER_ID_MISSING = 2022,
}
local messages = {}
function slurm.log_info (fmt, ...) end
function slurm.log_user (fmt, ...)
	table.insert(messages, string.format(fmt, ...))
end

dofile("job_submit.lua")

local part_list = {
	c = { name = "c", flag_default = 1 },
	m = { name = "m", flag_default = 0 },
	g = { name = "g", flag_default = 0 },
	grid = { name = "grid", flag_default = 0 },
}

-- A batch job as sbatch sends it, with fields overridden by opts
local function job (opts)
	local j = {
		script = "#!/bin/bash\nhostname\n",
		argc = 1,
		user_name = "tester",
		alloc_node = "cbe-login-1",
		shared = slurm.NO_VAL16,
		min_nodes = slurm.NO_VAL,
		num_tasks = slurm.NO_VAL,
		ntasks_per_node = slurm.NO_VAL16,
		sockets_per_node = slurm.NO_VAL16,
		min_cpus = 1,
		time_limit = 60,
	}
	for k, v in pairs(opts or {}) do
		j[k] = v
	end
	return j
end

local failures, count = 0, 0
local function check (name, j, want_rc, want)
	count = count + 1
	messages = {}
	local rc = slurm_job_submit(j, part_list, 1000)
	local ok = rc == want_rc
	for k, v in pairs(want or {}) do
		if j[k] ~= v then
			ok = false
		end
	end
	if not ok then
		failures = failures + 1
		print(string.format("FAIL %s: rc=%s qos=%s reservation=%s", name, tostring(rc),
			tostring(j.qos), tostring(j.reservation)))
		for i, m in ipairs(messages) do
			print("     " .. m)
		end
	else
		print("ok   " .. name)
	end
end

local OK, GRES, MEM = slurm.SUCCESS, slurm.ESLURM_INVALID_GRES, slurm.ESLURM_INVALID_TASK_MEMORY
local G = 1024

-- Partition m: 200 GB floor for batch jobs, 128 GB for interactive sessions
check("batch on m with 32G is rejected", job{ partition = "m", min_mem_per_node = 32 * G }, MEM)
check("batch on m with 250G is accepted", job{ partition = "m", min_mem_per_node = 250 * G }, OK,
	{ qos = "m_short" })
check("batch on m without --mem is rejected", job{ partition = "m" }, MEM)
check("batch on c,m with 32G is rejected", job{ partition = "c,m", min_mem_per_node = 32 * G }, MEM)
check("batch on m with 2G per CPU is accepted", job{ partition = "m", min_mem_per_cpu = 2 * G }, OK)
check("OOD RStudio on m with 128G is accepted",
	job{ partition = "m", alloc_node = "cbe-ood-1", min_mem_per_node = 128 * G }, OK,
	{ qos = "interactive" })
check("OOD RStudio on m with 64G is rejected",
	job{ partition = "m", alloc_node = "cbe-ood-1", min_mem_per_node = 64 * G }, MEM)
check("salloc on m with 128G is accepted",
	job{ partition = "m", script = "", min_mem_per_node = 128 * G }, OK, { qos = "interactive" })

-- salloc and srun without a batch script default to the interactive QOS
check("salloc without --qos gets interactive", job{ partition = "c", script = "" }, OK,
	{ qos = "interactive", reservation = "interactive" })
check("salloc without -p gets interactive and keeps its time limit", job{ script = "" }, OK,
	{ qos = "interactive", reservation = "interactive", time_limit = 60 })
check("salloc without -p and without --time gets 240 minutes",
	job{ script = "", time_limit = slurm.NO_VAL }, OK, { time_limit = 240 })
check("salloc with --time=600 is capped at 240 minutes",
	job{ partition = "c", script = "", time_limit = 600 }, OK, { time_limit = 240 })
check("salloc with --qos=long keeps it", job{ partition = "c", script = "", qos = "long" }, OK,
	{ qos = "c_long", reservation = nil })
check("salloc on grid keeps the grid QOS", job{ partition = "grid", script = "" }, OK,
	{ qos = nil })
check("sbatch without --qos gets short", job{ partition = "c" }, OK, { qos = "c_short" })
check("salloc on g with a GPU gets interactive_gpu",
	job{ partition = "g", script = "", tres_per_job = "gres/gpu:1" }, OK,
	{ qos = "interactive", reservation = "interactive_gpu" })

-- Partition g: 1 or more GPUs, and --exclusive only with all GPUs of the node
check("g without GPUs is rejected", job{ partition = "g" }, GRES)
check("c,g without GPUs is rejected", job{ partition = "c,g" }, GRES)
check("--qos=g_short without -p and without GPUs is accepted on the default partition",
	job{ qos = "g_short" }, OK)
check("--gpus=0 is rejected", job{ partition = "g", tres_per_job = "gres/gpu:0" }, GRES)
check("--gres=gpu:0 is rejected", job{ partition = "g", tres_per_node = "gres/gpu:0" }, GRES)
check("--gres=shard:1 is rejected", job{ partition = "g", tres_per_node = "gres/shard:1" }, GRES)
check("--gpus=1 is accepted", job{ partition = "g", tres_per_job = "gres/gpu:1" }, OK,
	{ qos = "g_short" })
check("--gres=gpu is accepted", job{ partition = "g", tres_per_node = "gres/gpu" }, OK)
check("--gpus=nvidia_b200:2 is accepted", job{ partition = "g", tres_per_job = "gres/gpu:nvidia_b200:2" }, OK)
check("MIG slice is accepted", job{ partition = "g", tres_per_job = "gres/gpu:nvidia_b200_1g.23gb:1" }, OK)
check("--gpus-per-task without --ntasks is rejected",
	job{ partition = "g", tres_per_task = "gres/gpu:1" }, slurm.ESLURM_BAD_TASK_COUNT)
check("--gpus-per-task with --ntasks is accepted",
	job{ partition = "g", tres_per_task = "gres/gpu:1", num_tasks = 2 }, OK)
check("--exclusive --gpus=1 is rejected",
	job{ partition = "g", tres_per_job = "gres/gpu:1", shared = 0 }, GRES)
check("--exclusive --gpus=4 is accepted",
	job{ partition = "g", tres_per_job = "gres/gpu:4", shared = 0 }, OK)
check("--exclusive -N2 --gpus-per-node=4 is accepted",
	job{ partition = "g", tres_per_node = "gres/gpu:4", min_nodes = 2, shared = 0 }, OK)
check("--exclusive -N2 --gpus=4 is rejected",
	job{ partition = "g", tres_per_job = "gres/gpu:4", min_nodes = 2, shared = 0 }, GRES)
check("--exclusive with 4 MIG slices is rejected",
	job{ partition = "g", tres_per_job = "gres/gpu:nvidia_b200_1g.23gb:4", shared = 0 }, GRES)
check("--exclusive --ntasks-per-node=4 --gpus-per-task=1 is accepted",
	job{ partition = "g", tres_per_task = "gres/gpu:1", num_tasks = 4, ntasks_per_node = 4, shared = 0 }, OK)
check("--exclusive=user --gpus=1 is accepted",
	job{ partition = "g", tres_per_job = "gres/gpu:1", shared = 2 }, OK)
check("--exclusive on c is accepted", job{ partition = "c", shared = 0 }, OK)

-- scontrol update of a running job
local function modify (name, desc, ptr, want_rc)
	count = count + 1
	local rc = slurm_job_modify(desc, ptr, part_list, 1000)
	if rc ~= want_rc then
		failures = failures + 1
		print(string.format("FAIL %s: rc=%s", name, tostring(rc)))
	else
		print("ok   " .. name)
	end
end
local base = { min_nodes = slurm.NO_VAL, max_nodes = slurm.NO_VAL, num_tasks = slurm.NO_VAL }
local function with (t)
	local d = {}
	for k, v in pairs(base) do d[k] = v end
	for k, v in pairs(t) do d[k] = v end
	return d
end
modify("modify to gpu:0 on g is rejected", with{ tres_per_node = "gres/gpu:0" },
	{ partition = "g", num_tasks = slurm.NO_VAL }, GRES)
modify("modify to gpu:2 on g is accepted", with{ tres_per_node = "gres/gpu:2" },
	{ partition = "g", num_tasks = slurm.NO_VAL }, OK)
modify("modify without GRES change is accepted", with{ time_limit = 30 },
	{ partition = "g", num_tasks = slurm.NO_VAL }, OK)

print(string.format("%d tests, %d failures", count, failures))
os.exit(failures == 0 and 0 or 1)
