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
	-- partition name (NOTE: a substring which begins the name), has gpus
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
	min_mem_per_node=700000,	-- Minimum memory per node in MB
	cores_per_node=32,		-- Cores per node (used to derive minimum memory per CPU)
}

--
-- Define functions to be used
--

-- Check for interactive jobs
function check_interactive_job (job_desc, part_list, submit_uid, log_prefix)
	if job_desc.script == nil or job_desc.script == "" then
		-- Job script is missing, so we assume that this is an interactive job
		slurm.log_info("%s: user %s submitted an interactive job to partition(s) %s",
			log_prefix, userinfo, job_desc.partition or "(default)")
		slurm.log_user("NOTICE: Job script is missing, assuming an interactive job")
		local max_time = interactive_max_time
		if job_desc.partition == nil or job_desc.partition == "" then	-- Just a sanity check of partition
			job_desc.time_limit = max_time	-- Set a new job max_time
			slurm.log_user("Interactive job time limit is set to %d minutes", max_time)
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
	local min_mem_per_cpu = highmem.min_mem_per_node / highmem.cores_per_node
	local usage_page="https://docs.vbc.ac.at/books/scientific-computing/chapter/cbenext"
	-- This check only applies to the high-memory partition (return otherwise)
	if string.find(job_desc.partition, highmem.partition, 1, true) ~= 1 then
		return slurm.SUCCESS
	end
	if job_desc.min_mem_per_node == nil and job_desc.min_mem_per_cpu == nil then
		-- Neither min_mem_per_node nor min_mem_per_cpu was specified
		slurm.log_info("%s: user %s %s Job did not specify min_mem_per_* for partition %s",
			log_prefix, userinfo, badstring, job_desc.partition)
		slurm.log_user("Big-memory partition %s requires jobs to specify memory explicitly.", job_desc.partition)
		slurm.log_user("See the Wiki page %s", usage_page)
		return slurm.ESLURM_INVALID_TASK_MEMORY
	end
	-- Note: With Lua 5.1.4 (CentOS 7) printing a nil value generates an error (fixed in 5.3.4),
	-- so we need to check carefully for any nil values (see bug 19564)
	if job_desc.min_mem_per_node ~= nil and job_desc.min_mem_per_node < min_mem_per_node then
		slurm.log_user("Big-memory partition %s requires jobs to specify a memory per node of at least %d MB",
			job_desc.partition, min_mem_per_node)
		slurm.log_user("Your job requested %s MB", job_desc.min_mem_per_node)
		slurm.log_user("See the Wiki page %s", usage_page)
		return slurm.ESLURM_INVALID_TASK_MEMORY
	end
	if job_desc.min_mem_per_cpu ~= nil and job_desc.min_mem_per_cpu < min_mem_per_cpu then
		slurm.log_user("Big-memory partition %s requires jobs to specify a memory per cpu of at least %d MB",
			job_desc.partition, min_mem_per_cpu)
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
	if string.find(job_desc.partition, "c", 1, true) ~= 1 then
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


-- Check if GPU partitions are used correctly
function check_gpus (job_desc, part_list, submit_uid, log_prefix)
	-- Loop over partitions
	for i, p in ipairs(partitions) do
		if p.has_gpus then
			-- Code adapted from https://lists.schedmd.com/pipermail/slurm-users/2020-December/006459.html
			if string.find(job_desc.partition,p.partition,1,true) == 1 then
				-- partition name begins with p.partition
				if job_desc.gres ~= nil then
					if string.find(job_desc.gres, "gpu") then
						-- Get number of GPUs specified and validate the count
						local numgpu = string.match(job_desc.gres, ":%d+$")
						if numgpu ~= nil then
							numgpu = numgpu:gsub(':', '')
							if tonumber(numgpu) < 1 then
								-- Alert on invalid gpu count - eg: gpu:0 , gpu:p100:0
								slurm.log_info("%s: user %s %s Invalid GPU count specified in GRES",
									log_prefix, userinfo, badstring)
								slurm.log_user("Invalid GPU count specified in GRES, must be greater than 0")
								slurm.log_user(script_error)
								return slurm.ESLURM_INVALID_GRES
							end
						end
					else
						-- GRES specified but no "gpu" was given
						slurm.log_info("%s: user %s %s No GPUs specified in GRES for GPU partition %s",
							log_prefix, userinfo, badstring, job_desc.partition)
						slurm.log_user("No GPU GRES was specified, GRES must be 1 or more GPUs in partition %s",
							job_desc.partition)
						slurm.log_user(script_error)
						return slurm.ESLURM_INVALID_GRES
					end
				elseif job_desc.tres_per_node ~= nil or job_desc.tres_per_socket ~= nil or job_desc.tres_per_task ~= nil then
					-- Alternative use of gpus in newer versions of slurm
					if job_desc.num_tasks == slurm.NO_VAL then
						slurm.log_user("--gpus-per-task option requires --tasks specification")
						slurm.log_user(script_error)
						return slurm.ESLURM_BAD_TASK_COUNT
					end
				else
					-- No GRES specified
					slurm.log_info("%s: user %s %s No GRES specified for GPU partition %s",
						log_prefix, userinfo, badstring, job_desc.partition)
					slurm.log_user("No GRES was specified, GRES must be 1 or more GPUs in partition %s",
						job_desc.partition)
					slurm.log_user(script_error)
					return slurm.ESLURM_INVALID_GRES
				end
				break	-- no more partitions to check
			end
		end
	end
	return slurm.SUCCESS
end

-- Construct and set the final QOS as "<partition>_<qos>"
function set_qos (job_desc, part_list, submit_uid, log_prefix)
	local qos = job_desc.qos
	local submit_part = job_desc.partition
	local is_grid_job = submit_part == "grid"
	if qos == nil then
		qos = default_qos
	end
	-- Skip if QOS already contains '_', meaning it has already been formatted
	if string.find(qos, '_') then
		return slurm.SUCCESS
	end
	if submit_part == nil then
      for name, part in pairs(part_list) do
        if part.flag_default ~= 0 then
          submit_part = part.name
		  slurm.log_info("%s: Job from user %s setting default partition value: %s",
									log_prefix, userinfo, submit_part)
          break
        end
       end
     end
	local result_qos = submit_part .. '_' .. qos
	job_desc.qos = result_qos
	job_desc.partition = submit_part
	slurm.log_info("%s: user %s setting QOS to %s", log_prefix, userinfo, result_qos)
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
	local functionlist = { check_arg_list, forbid_reserved_name, set_qos,
		check_interactive_job, check_time, check_big_memory, check_memory,
		forbid_memory_eq_0, check_gpus }

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
	local functionlist2 = { modify_partition, modify_num_nodes, modify_num_tasks }
	for i, func in ipairs(functionlist2) do
		check = func(job_desc, job_ptr, part_list, modify_uid, log_prefix)
		if check ~= slurm.SUCCESS then
			return check
		end
	end

	return slurm.SUCCESS
end
