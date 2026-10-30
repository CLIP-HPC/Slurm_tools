--[[
Niflheim job_submit.lua file for Slurm based upon the source file etc/job_submit.lua.example

For more information check https://slurm.schedmd.com/job_submit_plugins.html
An example is in the source code at .../etc/job_submit.lua.example
See also the Wiki page https://wiki.fysik.dtu.dk/Niflheim_system/Slurm_configuration/#job-submit-plugins

NOTES:
* The slurm.log_info() function logs to the slurmctld.log
    We print the "badstring" string to identify bad job submissions.
* The slurm.log_user() function prints an error message to the user's terminal.
* Slurm Error numbers are defined in the source file slurm/slurm_errno.h
* For the list of available Lua slurm.* fields check the job_desc variable
    in src/plugins/job_submit/lua/job_submit_lua.c
* The job_submit.lua file is called with these arguments:
    job_desc (input/output) the job allocation request specifications.
    job_ptr (input/output) slurmctld daemon's current data structure for the job to be modified.
    part_list (input) List of pointer to partitions which this user is authorized to use.
    modify_uid (input) user ID initiating the request.
    See https://slurm.schedmd.com/job_submit_plugins.html#lua

ERROR NUMBERS:
Error numbers are defined in the source file /usr/include/slurm/slurm_errno.h
Prior to Slurm 23.02 we have to define error symbols manually, see https://bugs.schedmd.com/show_bug.cgi?id=14500
Only a few selected symbols ESLURM_* were exposed to the Lua script, but from Slurm 23.02 all the error codes are exposed.
--]]

badstring="BAD:"	-- This string is printed to slurmctld.log and can be grepped for
userinfo=""
--[[
-- Prior to Slurm 23.02 we had to define these error codes:
slurm.ESLURM_INVALID_PARTITION_NAME=2000
slurm.ESLURM_INVALID_NODE_COUNT=2006
slurm.ESLURM_PATHNAME_TOO_LONG=2012
slurm.ESLURM_BAD_TASK_COUNT=2025
slurm.ESLURM_INVALID_TASK_MEMORY=2044
slurm.ESLURM_INVALID_GRES=2072
--]]

--
-- Define our partitions and defaults
--
partitions = {
	-- partition name (NOTE: the name, or a prefix followed by "_"), has gpus
	-- Multiple partitions can be lumped together, for example, xeon24, xeon24_512, xeon24_1024 as "xeon24"
	{ partition="c", has_gpus=false },
	{ partition="m", has_gpus=false },
	{ partition="g", has_gpus=true },
}
interactive_max_time=240	-- Default maximum time in minutes for all interactive jobs
default_qos="short"		-- Default QOS if none was requested
script_error="ERROR: Please modify your batch job script"

-- High-memory node configuration
highmem = {
	partition="m",			-- Partition name prefix for high-memory nodes
	min_mem_per_node=204800,	-- Minimum memory per node in MB for batch jobs
	interactive_min_mem_per_node=131072,	-- Minimum memory per node in MB for interactive sessions (OpenOnDemand, salloc)
	cores_per_node=160,		-- Cores per node (used to derive minimum memory per CPU)
}

-- Interactive sessions (OpenOnDemand, salloc, srun --pty)
-- See docs/adr/0001-interactive-reservations-and-qos.md in CLIP-HPC/clip-cbe-cluster
interactive = {
	qos="interactive",		-- QOS used as is, without the "<partition>_" prefix
	ood_alloc_node="^cbe%-ood%-",	-- Lua pattern matching the OpenOnDemand submit host(s)
	reservations={			-- partition name -> recurring FLEX reservation
		c="interactive",
		g="interactive_gpu",
	},
}

--
-- Define functions to be used
--

-- Return the list of partitions requested by the job (the default partition if none)
function job_partitions (job_desc, part_list)
	local parts = {}
	local requested = job_desc.partition or default_partition(part_list)
	if requested ~= nil then
		for part in string.gmatch(requested, "[^,]+") do
			table.insert(parts, part)
		end
	end
	return parts
end

-- True if partition part is the partition prefix or begins with prefix followed by "_"
-- (so that "g_long" belongs to "g", but "grid" does not)
function partition_matches (part, prefix)
	return part == prefix or string.find(part, prefix .. "_", 1, true) == 1
end

-- Return the first requested partition that matches prefix, or nil
function find_partition (job_desc, part_list, prefix)
	for i, part in ipairs(job_partitions(job_desc, part_list)) do
		if partition_matches(part, prefix) then
			return part
		end
	end
	return nil
end

-- True if the job has no batch script (salloc, srun outside an allocation)
function is_scriptless (job_desc)
	return job_desc.script == nil or job_desc.script == ""
end

-- Parse a TRES string such as "gres/gpu:2,gres/gpu:nvidia_b200_1g.23gb:1" (from --gpus*, --gres)
-- Returns the number of GPUs and whether any GPU was named
function count_gpus (tres)
	local total, named = 0, false
	if tres == nil then
		return total, named
	end
	for spec in string.gmatch(tres, "[^,]+") do
		if string.find(spec, "gpu", 1, true) then
			named = true
			total = total + (tonumber(string.match(spec, "[:=](%d+)$")) or 1)
		end
	end
	return total, named
end

-- Sum count_gpus over the --gpus*/--gres fields of job_desc
-- (job_desc.gres is an alias of tres_per_node, so it is not counted separately)
function count_job_gpus (job_desc)
	local total, named = 0, false
	for i, field in ipairs({ "tres_per_job", "tres_per_node", "tres_per_socket", "tres_per_task" }) do
		local t, n = count_gpus(job_desc[field])
		total, named = total + t, named or n
	end
	return total, named
end

-- --exclusive: Slurm allocates all CPUs and GPUs of each node, but only the requested memory.
-- Allocate all memory too, so that the accounting shows the whole node.
-- Must run after forbid_memory_eq_0, which rejects --mem=0 from users.
function set_exclusive_memory (job_desc, part_list, submit_uid, log_prefix)
	-- job_desc.shared is 0 (JOB_SHARED_NONE) for --exclusive, but not for --exclusive=user
	if job_desc.shared ~= 0 then
		return slurm.SUCCESS
	end
	if job_desc.min_mem_per_node ~= nil or job_desc.min_mem_per_cpu ~= nil or job_desc.mem_per_tres ~= nil then
		slurm.log_user("NOTICE: --exclusive allocates all memory of each node, the memory request is ignored")
	end
	-- min_mem_per_node and min_mem_per_cpu share one field in Slurm, so this replaces both
	job_desc.min_mem_per_node = 0
	if job_desc.mem_per_tres ~= nil then
		job_desc.mem_per_tres = nil	-- --mem-per-gpu
	end
	slurm.log_info("%s: user %s exclusive job gets all memory of each node", log_prefix, userinfo)
	return slurm.SUCCESS
end

-- Check for interactive jobs
function check_interactive_job (job_desc, part_list, submit_uid, log_prefix)
	if job_desc.script == nil or job_desc.script == "" then
		-- Job script is missing, so we assume that this is an interactive job
		slurm.log_info("%s: user %s submitted an interactive job to partition(s) %s",
			log_prefix, userinfo, job_desc.partition or "(default)")
		slurm.log_user("NOTICE: Job script is missing, assuming an interactive job")
		local max_time = interactive_max_time
		if job_desc.partition == nil or job_desc.partition == "" then	-- Just a sanity check of partition
			if job_desc.time_limit == nil or job_desc.time_limit > max_time then
				job_desc.time_limit = max_time	-- Set a new job max_time
				slurm.log_user("Interactive job time limit is set to %d minutes", max_time)
			end
			return slurm.SUCCESS
		end
		-- Loop over the (possibly multiple) partitions requested by the job
		--   Split job_desc.partition on the "," separator between multiple PartitionNames (such as a,b,c)
		--   See gmatch examples at http://lua-users.org/wiki/StringLibraryTutorial
		for pjob in string.gmatch(job_desc.partition, "[^,]+") do	-- Select substrings without comma ("^," means not-comma)
			-- Loop over partitions in part_list to determine the partition's max_time time limit
			for i, p in pairs(part_list) do
				if pjob == p.name then
					if p.max_time ~= nil and p.max_time < max_time then
						max_time = p.max_time		-- Reduce job max_time to the partition p.max_time
					end
					break	-- no more partitions to check
				end
			end
			if job_desc.time_limit == nil or job_desc.time_limit > max_time then
				job_desc.time_limit = max_time	-- Set a new job max_time
				slurm.log_info("%s: NOTICE: Job time_limit in partition %s has been set to %d minutes",
					log_prefix, pjob, max_time)
				slurm.log_user("        Job time limit is set to %d minutes on partition %s",
					max_time, pjob)
			end
		end
	end
	return slurm.SUCCESS
end

-- Warn if no time limit is specified
function check_time (job_desc, part_list, submit_uid, log_prefix)
	if job_desc.time_limit == slurm.NO_VAL then
		slurm.log_user("WARNING: No --time specified. Specify --time <walltime> to increase the chances that the scheduler uses this job for backfilling!")
	end
	return slurm.SUCCESS
end


-- Sanity check of partition modification
function modify_partition (job_desc, job_ptr, part_list, modify_uid, log_prefix)
	if job_desc.partition == nil or job_desc.partition == job_ptr.partition then
		-- The case where the modify request does not modify the partition name
		return slurm.SUCCESS
	else
		slurm.log_user("Change of partition not permitted: %s", job_desc.partition)
		return slurm.ESLURM_INVALID_PARTITION_NAME
	end
end

-- Sanity check of argument list in sbatch command:
--    sbatch [OPTIONS(0)...] [ : [OPTIONS(N)...]] script(0) [args(0)...]
-- Do not allow too long argument strings:
-- Very long strings might potentially cause Slurm to crash due to a database issue!
function check_arg_list (job_desc, part_list, submit_uid, log_prefix)
	local maxargc=10	-- Maximum number of job script arguments
	local maxarglen=1024	-- Maximum length of job script arguments, should be less than 1000000
	if job_desc.argc == 1 then
		return slurm.SUCCESS
	elseif job_desc.argc > (maxargc+1) then
		-- slurm.log_info("%s: user %s(%u) job_name=%s %s argc=%u is too large",
			-- log_prefix, job_desc.user_name, submit_uid, job_desc.name, badstring, job_desc.argc)
		slurm.log_info("%s: user %s %s argc=%u is too large",
			log_prefix, userinfo, badstring, job_desc.argc)
		slurm.log_user("ERROR: The number of script arguments %u is too large, maximum is %u",
			job_desc.argc - 1, maxargc)
		slurm.log_user(script_error)
		return slurm.ESLURM_PATHNAME_TOO_LONG
	else
		-- Calculate total length of argument strings
		local arglength=0
		for i = 1, job_desc.argc - 1 do
			if job_desc.argv[i] ~= nil then
				arglength = arglength + string.len(job_desc.argv[i]) + 1
			end
		end
		if arglength > maxarglen then
			-- slurm.log_info("%s: user %s(%u) job_name=%s %s argc=%u argv list length=%u",
				-- log_prefix, job_desc.user_name, submit_uid, job_desc.name, badstring, job_desc.argc, arglength)
			slurm.log_info("%s: user %s %s argc=%u argv list length=%u",
				log_prefix, userinfo, badstring, job_desc.argc, arglength)
			slurm.log_user("ERROR: The script argument list exceeds %u characters, length=%u",
				maxarglen, arglength)
			slurm.log_user(script_error)
			return slurm.ESLURM_PATHNAME_TOO_LONG
		end
		return slurm.SUCCESS
	end
end


-- Sanity check of modified number of nodes (default=slurm.NO_VAL)
function modify_num_nodes (job_desc, job_ptr, part_list, modify_uid, log_prefix)
	if job_desc.min_nodes == slurm.NO_VAL and job_desc.max_nodes == slurm.NO_VAL then
		-- The case where the modify request does not modify the min_nodes or max_nodes
		return slurm.SUCCESS
	else
		slurm.log_user("Change of number of nodes not permitted")
		return slurm.ESLURM_INVALID_NODE_COUNT
	end
end


-- Sanity check of modified number of tasks (default num_tasks=slurm.NO_VAL)
function modify_num_tasks (job_desc, job_ptr, part_list, modify_uid, log_prefix)
	-- The cases where the modify request does not modify the num_tasks
	if job_desc.num_tasks == slurm.NO_VAL then
		return slurm.SUCCESS
	elseif job_ptr.num_tasks ~= slurm.NO_VAL then
		if job_desc.num_tasks == job_ptr.num_tasks then
			return slurm.SUCCESS
		end
	end
	slurm.log_user("Change of number of tasks not permitted")
	return slurm.ESLURM_BAD_TASK_COUNT
end


--Forbid the use of jobname="MAINT"
function forbid_reserved_name (job_desc, part_list, submit_uid, log_prefix)
	local reserved="MAINT"
	if job_desc.name ~= nil and job_desc.name == reserved then
		slurm.log_info("%s: user %s %s JobName=%s reserved",
			log_prefix, userinfo, badstring, reserved)
		slurm.log_user("JobName=%s is reserved. Please use another job name.", reserved)
		slurm.log_user(script_error)
		return slurm.ERROR
	else
		return slurm.SUCCESS
	end
end

-- Check usage of big-memory nodes using --mem=xxx etc.
function check_big_memory (job_desc, part_list, submit_uid, log_prefix)
	local min_mem_per_node = highmem.min_mem_per_node
	if job_desc.qos == interactive.qos then
		min_mem_per_node = highmem.interactive_min_mem_per_node
	end
	local min_mem_per_cpu = min_mem_per_node / highmem.cores_per_node
	local usage_page="https://docs.vbc.ac.at/books/scientific-computing/chapter/cbenext"
	-- This check applies to jobs that may run in the high-memory partition (return otherwise)
	local part = find_partition(job_desc, part_list, highmem.partition)
	if part == nil or job_desc.shared == 0 then
		-- Exclusive jobs get all memory of the node (set_exclusive_memory)
		return slurm.SUCCESS
	end
	if job_desc.min_mem_per_node == nil and job_desc.min_mem_per_cpu == nil then
		-- Neither min_mem_per_node nor min_mem_per_cpu was specified
		slurm.log_info("%s: user %s %s Job did not specify min_mem_per_* for partition %s",
			log_prefix, userinfo, badstring, part)
		slurm.log_user("Big-memory partition %s requires jobs to specify memory explicitly.", part)
		slurm.log_user("See the Wiki page %s", usage_page)
		return slurm.ESLURM_INVALID_TASK_MEMORY
	end
	-- Note: With Lua 5.1.4 (CentOS 7) printing a nil value generates an error (fixed in 5.3.4),
	-- so we need to check carefully for any nil values (see bug 19564)
	if job_desc.min_mem_per_node ~= nil and job_desc.min_mem_per_node < min_mem_per_node then
		slurm.log_user("Big-memory partition %s requires jobs to specify a memory per node of at least %d MB",
			part, min_mem_per_node)
		slurm.log_user("Your job requested %s MB", job_desc.min_mem_per_node)
		slurm.log_user("See the Wiki page %s", usage_page)
		return slurm.ESLURM_INVALID_TASK_MEMORY
	end
	if job_desc.min_mem_per_cpu ~= nil and job_desc.min_mem_per_cpu < min_mem_per_cpu then
		slurm.log_user("Big-memory partition %s requires jobs to specify a memory per cpu of at least %d MB",
			part, min_mem_per_cpu)
		slurm.log_user("Your job requested %s MB", job_desc.min_mem_per_cpu)
		slurm.log_user("See the Wiki page %s", usage_page)
		return slurm.ESLURM_INVALID_TASK_MEMORY
	end
	return slurm.SUCCESS
end

-- Warn if a single-node job on the regular compute partition requests a high memory/core ratio
function check_memory (job_desc, part_list, submit_uid, log_prefix)
	local good_mem_core_ratio = 5000	-- MB per core considered a normal request
	-- Only applies to the regular compute partition
	if find_partition(job_desc, part_list, "c") == nil or job_desc.shared == 0 then
		return slurm.SUCCESS
	end
	-- Only warn for single-node jobs
	if job_desc.min_nodes ~= slurm.NO_VAL and job_desc.min_nodes > 1 then
		return slurm.SUCCESS
	end
	local mem_per_core = 4096 / job_desc.min_cpus
	if job_desc.min_mem_per_node ~= nil then
		mem_per_core = job_desc.min_mem_per_node / job_desc.min_cpus
	end
	if job_desc.min_mem_per_cpu ~= nil then
		mem_per_core = job_desc.min_mem_per_cpu
	end
	if mem_per_core > 2 * good_mem_core_ratio then
		slurm.log_user("WARNING: Job requested a high memory/core ratio (%s MB/core). Consider submitting to the 'm' partition for faster scheduling and better resource utilization!", mem_per_core)
	end
	return slurm.SUCCESS
end

-- Forbid unlimited memory using --mem=0 etc.
function forbid_memory_eq_0 (job_desc, part_list, submit_uid, log_prefix)
	local checklist = {
		{ name="--mem",		value=job_desc.min_mem_per_node },
		{ name="--mem-per-cpu",	value=job_desc.min_mem_per_cpu },
		{ name="--mem-per-gpu",	value=job_desc.min_mem_per_gpu }
	}
	for i, check in ipairs(checklist) do
		if check.value ~= nil and check.value == 0 then
			slurm.log_info("%s: user %s %s Memory %s=0 is not allowed",
				log_prefix, userinfo, badstring, check.name)
			slurm.log_user("Specifing ALL memory with %s=0 is not allowed", check.name)
			slurm.log_user(script_error)
			return slurm.ESLURM_INVALID_TASK_MEMORY
		end
	end
	return slurm.SUCCESS
end


-- Check if GPU partitions are used correctly:
-- Jobs that may run in a GPU partition must request 1 or more GPUs, so that CPU-only work
-- stays off the GPU nodes (--exclusive jobs get all GPUs of the node from Slurm anyway)
function check_gpus (job_desc, part_list, submit_uid, log_prefix)
	for i, p in ipairs(partitions) do
		if p.has_gpus then
			local part = find_partition(job_desc, part_list, p.partition)
			if part ~= nil then
				return check_gpu_request(job_desc, p, part, log_prefix)
			end
		end
	end
	return slurm.SUCCESS
end

-- Validate the GPU request of a job that may run in the GPU partition p (requested as part)
function check_gpu_request (job_desc, p, part, log_prefix)
	local total, named = count_job_gpus(job_desc)
	if not named then
		slurm.log_info("%s: user %s %s No GPUs requested for GPU partition %s",
			log_prefix, userinfo, badstring, part)
		slurm.log_user("Partition %s requires 1 or more GPUs, for example --gpus=1 or --gres=gpu:1", part)
		slurm.log_user(script_error)
		return slurm.ESLURM_INVALID_GRES
	end
	if total < 1 then
		slurm.log_info("%s: user %s %s Invalid GPU count requested for GPU partition %s",
			log_prefix, userinfo, badstring, part)
		slurm.log_user("Invalid GPU count requested, must be greater than 0 in partition %s", part)
		slurm.log_user(script_error)
		return slurm.ESLURM_INVALID_GRES
	end
	if (job_desc.tres_per_socket ~= nil or job_desc.tres_per_task ~= nil) and
			job_desc.num_tasks == slurm.NO_VAL then
		slurm.log_user("--gpus-per-task and --gpus-per-socket options require --ntasks specification")
		slurm.log_user(script_error)
		return slurm.ESLURM_BAD_TASK_COUNT
	end
	return slurm.SUCCESS
end

-- Sanity check of modified GPU requests in GPU partitions
function modify_gpus (job_desc, job_ptr, part_list, modify_uid, log_prefix)
	if job_desc.tres_per_job == nil and job_desc.tres_per_node == nil and
			job_desc.tres_per_socket == nil and job_desc.tres_per_task == nil then
		-- The case where the modify request does not modify the GPUs
		return slurm.SUCCESS
	end
	for i, p in ipairs(partitions) do
		if p.has_gpus and job_ptr.partition ~= nil then
			for part in string.gmatch(job_ptr.partition, "[^,]+") do
				if partition_matches(part, p.partition) then
					local total, named = count_job_gpus(job_desc)
					if not named or total < 1 then
						slurm.log_user("Partition %s requires 1 or more GPUs", part)
						return slurm.ESLURM_INVALID_GRES
					end
					return slurm.SUCCESS
				end
			end
		end
	end
	return slurm.SUCCESS
end

-- Return the name of the default partition from part_list (nil if there is none)
function default_partition (part_list)
	for name, part in pairs(part_list) do
		if part.flag_default ~= 0 then
			return part.name
		end
	end
	return nil
end

-- Construct and set the final QOS as "<partition>_<qos>"
function set_qos (job_desc, part_list, submit_uid, log_prefix)
	local qos = job_desc.qos
	local submit_part = job_desc.partition
	local is_grid_job = submit_part == "grid"
	if qos == nil then
		if is_scriptless(job_desc) and not is_grid_job then
			-- salloc and srun without a batch script are interactive sessions (see set_interactive)
			job_desc.qos = interactive.qos
			return slurm.SUCCESS
		end
		qos = default_qos
	end
	-- Skip if QOS already contains '_', meaning it has already been formatted
	-- The interactive QOS spans all partitions and has no prefix
	if string.find(qos, '_') or is_grid_job or qos == interactive.qos then
		return slurm.SUCCESS
	end
	if submit_part == nil then
		submit_part = default_partition(part_list)
		slurm.log_info("%s: Job from user %s setting default partition value: %s",
			log_prefix, userinfo, submit_part)
	end
	local result_qos = submit_part .. '_' .. qos
	job_desc.qos = result_qos
	job_desc.partition = submit_part
	slurm.log_info("%s: user %s setting QOS to %s", log_prefix, userinfo, result_qos)
	return slurm.SUCCESS
end

-- Interactive sessions: OpenOnDemand jobs, jobs requesting an interactive reservation,
-- and jobs requesting the interactive QOS all get the interactive QOS plus the
-- partition's interactive reservation. The reservations are FLEX, so jobs can start
-- outside the reservation window and outside the reserved resources.
-- Must run after set_qos, which turns an OpenOnDemand form QOS such as "short" into "c_short".
function set_interactive (job_desc, part_list, submit_uid, log_prefix)
	local is_ood = job_desc.alloc_node ~= nil and
		string.find(job_desc.alloc_node, interactive.ood_alloc_node) ~= nil
	local in_resv = false
	if job_desc.reservation ~= nil then
		for part, resv in pairs(interactive.reservations) do
			if job_desc.reservation == resv then
				in_resv = true
				break
			end
		end
	end
	if not (is_ood or in_resv or job_desc.qos == interactive.qos) then
		return slurm.SUCCESS
	end
	if job_desc.qos ~= interactive.qos then
		if job_desc.qos ~= nil and not is_ood then
			slurm.log_user("NOTICE: QOS %s replaced by %s for interactive sessions",
				job_desc.qos, interactive.qos)
		end
		job_desc.qos = interactive.qos
	end
	-- Multi-partition requests such as "c,g" match no entry and get no reservation
	local part = job_desc.partition or default_partition(part_list)
	local resv = part and interactive.reservations[part]
	if job_desc.reservation == nil and resv ~= nil then
		job_desc.reservation = resv
	end
	slurm.log_info("%s: user %s interactive session (ood=%s) partition=%s QOS=%s reservation=%s",
		log_prefix, userinfo, tostring(is_ood), part or "(default)", job_desc.qos,
		job_desc.reservation or "(none)")
	return slurm.SUCCESS
end

-- Sets a global string "userinfo" containing user, account and job information for this job
function get_userinfo (job_desc, part_list, submit_uid)
	if job_desc.account ~= nil then
		userinfo = string.format("%s(UID=%u) account=%s job_name=%s",
			job_desc.user_name, submit_uid, job_desc.account, job_desc.name)
	elseif job_desc.name ~= nil then
		-- The job's account is the user's default account
		userinfo = string.format("%s(UID=%u) job_name=%s",
			job_desc.user_name, submit_uid, job_desc.name)
	elseif submit_uid ~= nil then
		userinfo = string.format("%s(UID=%u) job_name=(nil)",
			job_desc.user_name, submit_uid)
	end
	return slurm.SUCCESS
end


function slurm_job_submit(job_desc, part_list, submit_uid)
	-- Arguments:
	-- job_desc (input/output) the job allocation request specifications.
	-- part_list (input) List of pointer to partitions which this user is authorized to use.
	-- submit_uid (input) user ID initiating the request.
	local log_prefix = 'slurm_job_submit'

	-- Don't block any activity from root. This may make reproduction of user errors difficult.
	if submit_uid == 0 then
		return slurm.SUCCESS
	end
	get_userinfo(job_desc, part_list, submit_uid)

	-- Loop over the function list
	-- We will call these functions in the order listed
	local functionlist = { check_arg_list, forbid_reserved_name, set_qos, set_interactive,
		check_interactive_job, check_time, forbid_memory_eq_0, set_exclusive_memory,
		check_big_memory, check_memory, check_gpus }

	local check = slurm.SUCCESS
	for i, func in ipairs(functionlist) do
		check = func(job_desc, part_list, submit_uid, log_prefix)
		if check ~= slurm.SUCCESS then
			return check
		end
	end

	return slurm.SUCCESS
end

function slurm_job_modify(job_desc, job_ptr, part_list, modify_uid)
	-- Arguments:
	-- job_desc (input/output) the job allocation **modification request** specifications.
	-- job_ptr (input/output) slurmctld daemon's **current** data structure for the job to be modified.
	-- part_list (input) List of pointer to partitions which this user is authorized to use.
	-- modify_uid (input) user ID initiating the request.
	local log_prefix = 'slurm_job_modify'

	--Don't block/modify any update from root
	if modify_uid == nil then
		return slurm.ESLURM_USER_ID_MISSING
	elseif modify_uid == 0 then
		return slurm.SUCCESS
	end
	get_userinfo(job_desc, part_list, modify_uid)

	-- Loop over the function list no. 1 for checking job_desc
	-- We will call these functions in the order listed
	local functionlist1 = { forbid_reserved_name, forbid_memory_eq_0 }

	local check = slurm.SUCCESS
	-- Warning: Calling log_user() from slurm_job_modify() fails when using Slurm < 23.02
	-- See https://bugs.schedmd.com/show_bug.cgi?id=14539
	for i, func in ipairs(functionlist1) do
		check = func(job_desc, part_list, modify_uid, log_prefix)
		if check ~= slurm.SUCCESS then
			return check
		end
	end
	-- Loop over the function list no. 2 for checking job_desc as well as job_ptr
	local functionlist2 = { modify_partition, modify_num_nodes, modify_num_tasks, modify_gpus }
	for i, func in ipairs(functionlist2) do
		check = func(job_desc, job_ptr, part_list, modify_uid, log_prefix)
		if check ~= slurm.SUCCESS then
			return check
		end
	end

	return slurm.SUCCESS
end
