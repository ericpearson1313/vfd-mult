################################################################################
# Copyright 2019 Eric Pearson
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
################################################################################

`define BUILD_NUMBER C020

//Build phase A - base version from Supranational

//Build phase B - Purpose: Area estimate, will it fit? 
//  Added: mult output shift register, and full adder to get the complete squared value, full residual luts (x4!), full adder (128 terms)
//  Added: B003 pipelined LUT output to divide luts in half.

//Build phase C - Purpose: acheive density & functionallity without performance
//  C004 : Detailed control and datapath. 6 lut, 205 input add - extra luts passed limit (used 4K brams, instead of 2K brams and 2K and gates
//  C005 : updated reduction lut gen to write out separate 256 entry tables for V54 and V76 separately, and add reduction lut full to do whole thing
//  C006 : Fixed all build errors and restored out_valid.
//  C007 : switch back to dual reduction lut (+2ns) for fit., runs, 10ns, 9 cycle. not functional
//  C008 : connect up missing prod acc inputs
//  C009 : try 10x multipliers :) 
//  C010 : try single 1024bit square unit ~size of 8x multipliers. (compiled ok)
//  C011 : remove reduction lut output muxing, async multiplies trial (clock too slow)
//  C012 : change to async lutram (clock will be very slow, but lets see)
//  C013 : fixup lut shifted outputs (failed to route,  Phase 3.1.2 Run Global Routing for 12 hours)
//  C014 : simulated base functional design (still 2207 of 2211 mults?)
//  C015 : change from CSA to adder trees. simulated and trial synth done, routed >36 Mhz
//  C016 : use multi cycle path (4 cycle) as SDaccel does not support < 60 Mhz (our best target is 42 Mhz)
//  C017 : 2 cycle clock enable
//  C018 : add start_d1 as multi-cycle source
//  C019 : functional, 2 pre-cycles, then 2 cycle with multi-cycle paths
//  C020 : functional, 4 pre-cycles, then 4 cycle with multi-cycle paths, target 144 Mhz

//Planned: Build D - Purpose: Performance
//Planned: Build E - multi-cycle funcitonallity
