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

`define BUILD_NUMBER C008

//Build phase A - base version from Supranational

//Build phase B - Purpose: Area estimate, will it fit? 
//  Added: mult output shift register, and full adder to get the complete squared value, full residual luts (x4!), full adder (128 terms)
//  Added: B003 pipelined LUT output to divide luts in half.

//Build phase C - Purpose: acheive functionallity without performance
//  C004 : Detailed control and datapath. 6 lut, 205 input add - extra luts passed limit (used 4K brams, instead of 2K brams and 2K and gates
//  C005 : updated reduction lut gen to write out separate 256 entry tables for V54 and V76 separately, and add reduction lut full to do whole thing
//  C006 : Fixed all build errors and restored out_valid.
//  C007 : switch back to dual reduction lut (+2ns) for fit., runs, 10ns, 9 cycle. not functional
//  C008 : connect up missing prod acc inputs

//Planned: Build D - Purpose: Performance
//Planned: Build E - multi-cycle funcitonallity
