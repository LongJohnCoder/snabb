-- pmu.lua: Lua interface to the CPU Performance Monitoring Unit
module(..., package.seeall)

-- This module counts and reports on CPU events such as cache misses,
-- branch mispredictions, utilization of internal CPU resources such
-- as execution units, and so on.
-- 
-- Hundreds of low-level counters are available. The exact list
-- depends on CPU model. See pmu_cpu.lua for our definitions.
-- 
-- API:
-- 
-- profile(fn, event_list) => <printed report>
--   Execute 'fn' and print a measurement report for event_list.
--   This is a simple convenience function over the API below.
-- 
-- is_available() => true | false, why
--   Return true if hardware performance counters are available.
--   Otherwise return false with a string briefly explaining why.
-- 
-- setup(event_list)
--   Setup the hardware performance counters to track a given list of
--   events (in addition to the built-in fixed-function counters).
-- 
--   Return the number of overflowed counters that could not be
--   tracked due to hardware constraints. These will be the last
--   counters in the list.
-- 
--   Example:
--     setup({"uops_issued.any",
--            "uops_retired.all",
--            "br_inst_retired.conditional",
--            "br_misp_retired.all_branches"}) => 0
-- 
-- new_counter_set()
--   Return a "counter_set" object that can be used for accumulating events.
-- 
--   The counter_set will be valid only until the next call to setup().
-- 
-- switch(counter_set)
--   Switch to a new set of counters to accumulate events in. Has the
--   side-effect of committing the current accumulators to the
--   previous record.
-- 
--   If counter_set is nil then do not accumulate events.
-- 
-- to_table(counter_set) => table {eventname = count}
--   Return a table containing the values accumulated in the counter set.
-- 
-- Example:
--   to_table(cs) =>
--     {
--      -- Fixed-function counters
--      instructions                 = 133973703,
--      cycles                       = 663011188,
--      ref-cycles                   = 664029720,
--      -- General purpose counters selected with setup()
--      uops_issued.any              = 106860997,
--      uops_retired.all             = 106844204,
--      br_inst_retired.conditional  =  26702830,
--      br_misp_retired.all_branches =       419
--     }
-- 
-- report(counter_set,  auxnames, auxvalues)
--   Print a textual report on the values accumulated in a counter set.
--   Optionally include auxiliary application-level counters. The
--   ratio of each event to each auxiliary counter is also reported.
-- 
--   Example:
--     report(my_counter_set, {packet = 26700000, breath = 208593})
--   prints output approximately like:
--     EVENT                                   TOTAL     /packet     /breath
--     instructions                      133,973,703       5.000     642.000
--     cycles                            663,011,188      24.000    3178.000
--     ref-cycles                        664,029,720      24.000    3183.000
--     uops_issued.any                   106,860,997       4.000     512.000
--     uops_retired.all                  106,844,204       4.000     512.000
--     br_inst_retired.conditional        26,702,830       1.000     128.000
--     br_misp_retired.all_branches              419       0.000       0.000
--     packet                             26,700,000       1.000     128.000
--     breath                                208,593       0.008       1.000

local pmu_cpu = require("lib.pmu_cpu")
local pmu_x86 = require("lib.pmu_x86")
local ffi = require("ffi")
local lib = require("core.lib")

local S = require("syscall")

-- defs: counter definitions
--   nil => not initialized
--   false => none available
--   table => name->code mappings
local defs = nil

-- enabled: array of names of the enabled counters
local enabled = nil

-- Scan the counter definitions for the set of counters that are
-- available on the running CPU.
local function scan_available_counters ()
   if defs then return defs end
   for i, set in ipairs(pmu_cpu) do
      local cpu, version, kind, list = unpack(set)
      -- XXX Only supporting "core" counters at present i.e. the
      -- counters built into the CPU core.
      if cpu == pmu_x86.cpu_model and kind == 'core' then
         defs = defs or {}
         for k, v in pairs(list) do defs[k] = v end
      end
   end
   defs = defs or false
end

-- Return an array containing the CPUs that we have affinity with.
local function cpu_set ()
   local t = {}
   local set = S.sched_getaffinity()
   for i = 0, 63 do
      if set:get(i) then table.insert(t, i) end
   end
   return t
end

-- Return true if PMU functionality is available. 
-- Otherwise return false and a string explaining why.
function is_available ()
   if #cpu_set() ~= 1 then
      return false, "single core cpu affinity required" 
   end
   if not S.stat("/dev/cpu/0/msr") then
      print("[pmu: /sbin/modprobe msr]")
      os.execute("/sbin/modprobe msr")
      if not S.stat("/dev/cpu/0/msr") then
         return false, "requires /dev/cpu/*/msr (Linux 'msr' module)"
      end
   end
   scan_available_counters()
   if not defs then
      return false, "CPU not recognized: " .. pmu_x86.cpu_model
   end
   return true
end

print("n", pmu_x86.ncounters)
counter_set_t = ffi.typeof("int64_t [$]", pmu_x86.ncounters)

function new_counter_set ()
   return ffi.new(counter_set_t)
end

local current_counter_set = nil
local base_counters = ffi.new(counter_set_t)
local tmp_counters = ffi.new(counter_set_t)

function switch (set)
   -- Credit the previous counter set for its events
   if current_counter_set then
      pmu_x86.rdpmc_multi(tmp_counters)
      for i = 0, pmu_x86.ncounters-1 do
         local v = tmp_counters[i] - base_counters[i]
         -- Account for wrap-around of the 40-bit counter value.
         if v < 0 then v = v + bit.lshift(1, 40) end
      end
   end
end

-- API function (see above)
function setup (set)
   set = lib.array_copy(set)
   local ndropped = math.max(0, #set - pmu_x86.ngeneral)
   if ndropped > 0 then set[pmu_x86.ngeneral+1] = nil end
   local avail, err = is_available()
   if not avail then
      error("PMU not available: " .. err)
   end
   local cpu = cpu_set()[1]
   -- Enable all fixed-function counters (IA32_FIXED_CTR_CTRL)
   writemsr(0, 0x38d, 0x333)
   for n = 0, #set-1 do
      local code = defs[set[n+1]]
      local USR = bit.lshift(1, 16)
      local EN = bit.lshift(1, 22)
      writemsr(0, 0x186+n, bit.bor(0x10000, USR, EN, code))
   end
   enabled = set
   return ndropped
end

function writemsr (cpu, msr, value)
   local msrfile = ("/dev/cpu/%d/msr"):format(cpu)
   if not S.stat(msrfile) then
      error("Cannot open "..msr.." (consider 'modprobe msr')")
   end
   local fd = assert(S.open(msrfile, "rdwr"))
   assert(fd:lseek(msr, "set"))
   assert(fd:write(ffi.new("uint64_t[1]", value), 8))
   fd:close()
end

-- Parameters are all optional.
function report (names, values, auxnames, auxvalues)
   -- print titles
   io.write(("%-30s %14s"):format("EVENT", "TOTAL"))
   for i = 1, #auxnames do
      io.write(("%12s"):format("/"..auxnames[i]))
   end
   print()
   -- include aux values in results
   for i = 1, #auxnames do
      table.insert(names, auxnames[i])
      table.insert(values, auxvalues[i])
   end
   -- print values
   for i = 1, #names do
      io.write(("%-30s %14s"):format(names[i], core.lib.comma_value(values[i])))
      for j = 1, #auxnames do
         io.write(("%12.3f"):format(tonumber(values[i]/auxvalues[j])))
      end
      print()
   end
end

function selftest ()
   print("selftest: pmu")
   local avail, err = is_available()
   if not avail then
      print("PMU not available:")
      print("  "..err)
      print("selftest skipped")
      os.exit(engine.test_skipped_code)
   end
   local n = 0
   if type(defs) == 'table' then 
      for k,v in pairs(defs) do n=n+1 end   
   end
   print(tostring(n).." counters found for CPU model "..pmu_x86.cpu_model)
   setup({"uops_issued.any",
          "uops_retired.all",
          "br_inst_retired.conditional",
          "br_misp_retired.all_branches"})
   local buf0 = ffi.new("uint64_t[7]")
   local buf1 = ffi.new("uint64_t[7]")
   local nloop = 2.67e7
   local acc = 0
   pmu_x86.rdpmc_multi(buf0)
   for i = 0, nloop do acc = acc / 1.2 + 1 end
   pmu_x86.rdpmc_multi(buf1)
   local names = {"instructions", "cycles", "ref-cycles"}
   for i = 1, #enabled do table.insert(names, enabled[i]) end
   local values = {}
   for i = 1, #names do values[i] = buf1[i-1] - buf0[i-1] end
   report(names, values, {"packet", "breath"}, {nloop, math.floor(nloop/128)})
   print("selftest ok")
end

