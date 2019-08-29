/*******************************************************************************
  Copyright 2019 Eric Pearson

  Licensed under the Apache License, Version 2.0 (the "License");
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.
*******************************************************************************/

// Enable 26x17 bit multiplies (17x17 bit multiplies if commented out)
//`define DSP26BITS 1

module modular_square_8_cycles
   #(
     parameter int REDUNDANT_ELEMENTS    = 2,
     parameter int NONREDUNDANT_ELEMENTS = 64,
     parameter int NUM_SEGMENTS          = 4,
     parameter int BIT_LEN               = 17,
     parameter int WORD_LEN              = 16,

     parameter int NUM_ELEMENTS          = ( REDUNDANT_ELEMENTS + NONREDUNDANT_ELEMENTS )
    )
   (
    input logic                   clk,
    input logic                   reset,
    input logic                   start,
    input logic [BIT_LEN-1:0]     sq_in[NUM_ELEMENTS],
    output logic [BIT_LEN-1:0]    sq_out[NUM_ELEMENTS],
    output logic                  valid
   );

   localparam int SEGMENT_ELEMENTS    = ( int'(NONREDUNDANT_ELEMENTS / NUM_SEGMENTS) );
   localparam int MUL_NUM_ELEMENTS    = ( REDUNDANT_ELEMENTS + SEGMENT_ELEMENTS );

   localparam int EXTRA_ELEMENTS      = 2;
   localparam int ONE_SEGMENT         = (  SEGMENT_ELEMENTS    + EXTRA_ELEMENTS + REDUNDANT_ELEMENTS );
   localparam int TWO_SEGMENTS        = ( (SEGMENT_ELEMENTS*2) + EXTRA_ELEMENTS + REDUNDANT_ELEMENTS );
   localparam int THREE_SEGMENTS      = ( (SEGMENT_ELEMENTS*3) + EXTRA_ELEMENTS + REDUNDANT_ELEMENTS );

   localparam int NUM_MULTIPLIERS     = 2;
   localparam int EXTRA_MUL_TREE_BITS = ( (BIT_LEN > WORD_LEN)         ?
                                           $clog2(MUL_NUM_ELEMENTS)    :
                                           $clog2(MUL_NUM_ELEMENTS*2) );
   localparam int MUL_BIT_LEN         = ( ((BIT_LEN*2) - WORD_LEN) + EXTRA_MUL_TREE_BITS );

   // Accumulator tree adds up to 9 values together of various lengths
   // 1*BIT_LEN
   // 4*WORD_LEN
   // 4*(MUL_BIT_LEN - WORD_LEN)
   // Brute force method here to calculate bits needed for sum
   // Note this doesn't work for 64b and above
   // TODO - need better method here, not using large conditionals though
   localparam longint MAX_VALUE       = ( ((2**BIT_LEN)-1)           +
                                          (((2**WORD_LEN)-1) << 2)   +
                                          (((2**(MUL_BIT_LEN-WORD_LEN))-1) << 2) );
   localparam int GRID_BIT_LEN        = ( $clog2(MAX_VALUE) );
   localparam int GRID_PAD            = ( GRID_BIT_LEN - WORD_LEN );
   localparam int GRID_PAD_CARRY      = ( GRID_BIT_LEN - (MUL_BIT_LEN - WORD_LEN) );
   localparam int GRID_PAD_C_SHIFT    = ( GRID_PAD_CARRY - 1 );
   localparam int GRID_PAD_RESULT     = ( GRID_BIT_LEN - BIT_LEN );
   localparam int GRID_NUM_ELEMENTS   = 16;

   // TODO - The +1 is not really needed.  Used in loops below for convenience
   // Because there is a j+1 in setting carry over
   // Full adder for complete sqaure
   localparam int GRID_SIZE           = ( (MUL_NUM_ELEMENTS*8) + 1 + (MUL_NUM_ELEMENTS - REDUNDANT_ELEMENTS) );
   localparam int LOOK_UP_WIDTH       = ( int'(WORD_LEN / 2) );
   localparam int LUT_SIZE            = ( 2**LOOK_UP_WIDTH );
   localparam int LUT_MASK            = ( (2**LOOK_UP_WIDTH)-1 );
   localparam int LUT_WIDTH           = ( WORD_LEN * NONREDUNDANT_ELEMENTS );

   localparam int ACC_ELEMENTS        = TWO_SEGMENTS;
   localparam int ACC_EXTRA_ELEMENTS  = 1; // Addin the lower bits of the product
   localparam int ACC_EXTRA_BIT_LEN   = 12; // WAS: $clog2(ACC_ELEMENTS+ACC_EXTRA_ELEMENTS);
   localparam int ACC_BIT_LEN         = ( BIT_LEN + ACC_EXTRA_BIT_LEN );

   localparam int IDLE                = 0,
                  CYCLE_0             = 1,
                  CYCLE_1             = 2,
                  CYCLE_2             = 3,
                  CYCLE_3             = 4,
                  CYCLE_4             = 5,
                  CYCLE_5             = 6,
                  CYCLE_6             = 7,
                  CYCLE_7             = 8,
                  CYCLE_8             = 9,
                  NUM_CYCLES          = 10;

   // Flop incoming data from external source
   logic [BIT_LEN-1:0]       sq_in_d1[NUM_ELEMENTS];
   logic                     start_d1;

   // Input to square (start of phase 1)
   logic [BIT_LEN-1:0]       curr_sq_in[NUM_ELEMENTS];

   // Cycle number state machine
   logic [NUM_CYCLES-1:0]    next_cycle;
   logic [NUM_CYCLES-1:0]    curr_cycle;

   // Multiplier selects in/out and values
   logic [1:0]               mul_A_select[NUM_MULTIPLIERS];
   logic [1:0]               mul_B_select[NUM_MULTIPLIERS];
   logic [BIT_LEN-1:0]       mul_A[NUM_MULTIPLIERS][MUL_NUM_ELEMENTS];
   logic [BIT_LEN-1:0]       mul_B[NUM_MULTIPLIERS][MUL_NUM_ELEMENTS];
   logic [MUL_BIT_LEN-1:0]   mul_cout[NUM_MULTIPLIERS][MUL_NUM_ELEMENTS*2];
   logic [MUL_BIT_LEN-1:0]   mul_s[NUM_MULTIPLIERS][MUL_NUM_ELEMENTS*2];
   reg   [MUL_BIT_LEN-1:0]   mul_reg0_cout[NUM_MULTIPLIERS][MUL_NUM_ELEMENTS*2];
   reg   [MUL_BIT_LEN-1:0]   mul_reg0_s[NUM_MULTIPLIERS][MUL_NUM_ELEMENTS*2];
   reg   [MUL_BIT_LEN-1:0]   mul_reg1_cout[NUM_MULTIPLIERS][MUL_NUM_ELEMENTS*2];
   reg   [MUL_BIT_LEN-1:0]   mul_reg1_s[NUM_MULTIPLIERS][MUL_NUM_ELEMENTS*2];
   reg   [MUL_BIT_LEN-1:0]   mul_reg2_cout[NUM_MULTIPLIERS][MUL_NUM_ELEMENTS*2];
   reg   [MUL_BIT_LEN-1:0]   mul_reg2_s[NUM_MULTIPLIERS][MUL_NUM_ELEMENTS*2];
   reg   [MUL_BIT_LEN-1:0]   mul_reg3_cout[NUM_MULTIPLIERS][MUL_NUM_ELEMENTS*2];
   reg   [MUL_BIT_LEN-1:0]   mul_reg3_s[NUM_MULTIPLIERS][MUL_NUM_ELEMENTS*2];

   logic [GRID_BIT_LEN-1:0]  grid[GRID_SIZE][GRID_NUM_ELEMENTS];
   logic [GRID_BIT_LEN-1:0]  C[GRID_SIZE];
   logic [GRID_BIT_LEN-1:0]  S[GRID_SIZE];

   logic [GRID_BIT_LEN:0]    grid_sum[GRID_SIZE];
   logic [BIT_LEN-1:0]       reduced_grid_sum[GRID_SIZE];
   reg   [BIT_LEN-1:0]       reduced_grid_reg[GRID_SIZE];

   logic [BIT_LEN-1:0]       v7v6[ACC_ELEMENTS];
   logic [BIT_LEN-1:0]       v5_partial[SEGMENT_ELEMENTS];
   logic [BIT_LEN-1:0]       v5v4_partial[ACC_ELEMENTS];
   logic [BIT_LEN-1:0]       v5v4[ACC_ELEMENTS];
   logic [BIT_LEN-1:0]       v3_partial[SEGMENT_ELEMENTS];
   // TODO - does v3 need to be ONE_SEGMENT
   logic [BIT_LEN-1:0]       v3[SEGMENT_ELEMENTS+REDUNDANT_ELEMENTS];
   logic [BIT_LEN-1:0]       v2_partial[SEGMENT_ELEMENTS];
   logic [BIT_LEN-1:0]       v2v0[THREE_SEGMENTS];

   logic [BIT_LEN-1:0]       curr_lookup_segment[ACC_ELEMENTS];
   logic                     curr_lookup_shift;
   logic                     curr_lookup_upper_table;
   logic                     curr_lookup_check_overflow;
   logic                     curr_overflow;
   logic                     set_overflow;
   logic                     v7v6_overflow;
   logic                     v5v4_overflow;
   logic [LOOK_UP_WIDTH:0]   lut_addr0[ACC_ELEMENTS];
   reg   [BIT_LEN-1:0]       lut_data0[NUM_ELEMENTS][ACC_ELEMENTS];
   logic [LOOK_UP_WIDTH:0]   lut_addr1[ACC_ELEMENTS];
   wire  [BIT_LEN-1:0]       lut_data1[NUM_ELEMENTS][ACC_ELEMENTS];
   logic [LOOK_UP_WIDTH:0]   lut_addr2[ACC_ELEMENTS];
   reg   [BIT_LEN-1:0]       lut_data2[NUM_ELEMENTS][ACC_ELEMENTS];
   logic [LOOK_UP_WIDTH:0]   lut_addr3[ACC_ELEMENTS];
   wire  [BIT_LEN-1:0]       lut_data3[NUM_ELEMENTS][ACC_ELEMENTS];
   logic [LOOK_UP_WIDTH:0]   lut_addr4[ACC_ELEMENTS];
   wire  [BIT_LEN-1:0]       lut_data4[NUM_ELEMENTS][ACC_ELEMENTS];
   logic [LOOK_UP_WIDTH:0]   lut_addr5[ACC_ELEMENTS];
   wire  [BIT_LEN-1:0]       lut_data5[NUM_ELEMENTS][ACC_ELEMENTS];



   logic [ACC_BIT_LEN-1:0]   acc_stack[NUM_ELEMENTS][3*2*SEGMENT_ELEMENTS+3*ACC_ELEMENTS+ACC_EXTRA_ELEMENTS];
   logic [ACC_BIT_LEN-1:0]   acc_C[NUM_ELEMENTS];
   logic [ACC_BIT_LEN-1:0]   acc_S[NUM_ELEMENTS];

   logic [ACC_BIT_LEN:0]     acc_sum[NUM_ELEMENTS];
   logic [BIT_LEN-1:0]       reduced_acc_sum[NUM_ELEMENTS];

   logic                     out_valid;

   // State machine setting values based on current cycle
   always_comb begin
      next_cycle                  = '0;
      out_valid                   = 1'b0;
      mul_A_select[0]             = 2'b00;
      mul_B_select[0]             = 2'b00;
      mul_A_select[1]             = 2'b00;
      mul_B_select[1]             = 2'b00;

      if (reset) begin
         next_cycle               = '0;
         next_cycle[IDLE]         = 1'b1;
         out_valid                = 1'b0;
      end
      else begin
         unique case(1'b1)
            curr_cycle[IDLE]: begin
               if (start) begin
                  next_cycle[CYCLE_0]      = 1'b1;
               end
               else begin
                  next_cycle[IDLE]         = 1'b1;
               end
            end
            curr_cycle[CYCLE_0]: begin
               mul_A_select[0]             = 2'b11;
               mul_B_select[0]             = 2'b10;
               mul_A_select[1]             = 2'b11;
               mul_B_select[1]             = 2'b11;
               next_cycle[CYCLE_1]         = 1'b1;
            end
            curr_cycle[CYCLE_1]: begin
               mul_A_select[0]             = 2'b10;
               mul_B_select[0]             = 2'b10;
               mul_A_select[1]             = 2'b11;
               mul_B_select[1]             = 2'b01;
               next_cycle[CYCLE_2]         = 1'b1;
            end
            curr_cycle[CYCLE_2]: begin
               mul_A_select[0]             = 2'b11;
               mul_B_select[0]             = 2'b00;
               mul_A_select[1]             = 2'b10;
               mul_B_select[1]             = 2'b01;
               next_cycle[CYCLE_3]         = 1'b1;
            end
            curr_cycle[CYCLE_3]: begin
               mul_A_select[0]             = 2'b10;
               mul_B_select[0]             = 2'b00;
               mul_A_select[1]             = 2'b01;
               mul_B_select[1]             = 2'b01;
               next_cycle[CYCLE_4]         = 1'b1;
            end
            curr_cycle[CYCLE_4]: begin
               mul_A_select[0]             = 2'b00;
               mul_B_select[0]             = 2'b00;
               mul_A_select[1]             = 2'b01;
               mul_B_select[1]             = 2'b00;
               next_cycle[CYCLE_5]         = 1'b1;
            end
            curr_cycle[CYCLE_5]: begin
               next_cycle[CYCLE_6]         = 1'b1;
            end
            curr_cycle[CYCLE_6]: begin
               next_cycle[CYCLE_7]         = 1'b1;
            end
            curr_cycle[CYCLE_7]: begin
               next_cycle[CYCLE_8]         = 1'b1;
            end
            curr_cycle[CYCLE_8]: begin
               next_cycle[CYCLE_0]         = 1'b1;
               out_valid                   = 1'b1;
            end
         endcase
      end
   end

   // Drive output valid signal
   // Flop incoming start signal and data
   always_ff @(posedge clk) begin
      if (reset) begin
         valid                       <= 1'b0;
         start_d1                    <= 1'b0;
      end
      else begin
         valid                       <= out_valid;

         // Keep start high once set until sq_out is valid for loopback
         start_d1                    <= start || (start_d1 && ~out_valid);
      end

      curr_cycle                     <= next_cycle;

      if (start) begin
         for (int k=0; k<NUM_ELEMENTS; k=k+1) begin
            sq_in_d1[k][BIT_LEN-1:0] <= sq_in[k][BIT_LEN-1:0];
         end 
      end
   end

   // Mux square input from external or loopback
   always_comb begin
      for (int k=0; k<NUM_ELEMENTS; k=k+1) begin
         curr_sq_in[k][BIT_LEN-1:0]    = sq_out[k][BIT_LEN-1:0];
         if (start_d1) begin
            curr_sq_in[k][BIT_LEN-1:0] = sq_in_d1[k][BIT_LEN-1:0];
         end
      end
   end

   always_comb begin
      // Select multiplier input sources
      for (int k=0; k<NUM_MULTIPLIERS; k=k+1) begin
         for (int l=0; l<SEGMENT_ELEMENTS; l=l+1) begin
            unique case(mul_A_select[k])
               2'b00: begin mul_A[k][l][BIT_LEN-1:0] = curr_sq_in[(SEGMENT_ELEMENTS*0)+l][BIT_LEN-1:0]; end
               2'b01: begin mul_A[k][l][BIT_LEN-1:0] = curr_sq_in[(SEGMENT_ELEMENTS*1)+l][BIT_LEN-1:0]; end
               2'b10: begin mul_A[k][l][BIT_LEN-1:0] = curr_sq_in[(SEGMENT_ELEMENTS*2)+l][BIT_LEN-1:0]; end
               2'b11: begin mul_A[k][l][BIT_LEN-1:0] = curr_sq_in[(SEGMENT_ELEMENTS*3)+l][BIT_LEN-1:0]; end
            endcase

            unique case(mul_B_select[k])
               2'b00: begin mul_B[k][l][BIT_LEN-1:0] = curr_sq_in[(SEGMENT_ELEMENTS*0)+l][BIT_LEN-1:0]; end
               2'b01: begin mul_B[k][l][BIT_LEN-1:0] = curr_sq_in[(SEGMENT_ELEMENTS*1)+l][BIT_LEN-1:0]; end
               2'b10: begin mul_B[k][l][BIT_LEN-1:0] = curr_sq_in[(SEGMENT_ELEMENTS*2)+l][BIT_LEN-1:0]; end
               2'b11: begin mul_B[k][l][BIT_LEN-1:0] = curr_sq_in[(SEGMENT_ELEMENTS*3)+l][BIT_LEN-1:0]; end
            endcase
         end

         // Redundant elements are only used as extension to highest element
         for (int l=REDUNDANT_ELEMENTS; l>0; l=l-1) begin
            mul_A[k][MUL_NUM_ELEMENTS-l][BIT_LEN-1:0] = '0;
            mul_B[k][MUL_NUM_ELEMENTS-l][BIT_LEN-1:0] = '0;
            if (mul_A_select[k] == 2'b11) begin
               mul_A[k][MUL_NUM_ELEMENTS-l][BIT_LEN-1:0] = curr_sq_in[NUM_ELEMENTS-l][BIT_LEN-1:0];
            end
            if (mul_B_select[k] == 2'b11) begin
               mul_B[k][MUL_NUM_ELEMENTS-l][BIT_LEN-1:0] = curr_sq_in[NUM_ELEMENTS-l][BIT_LEN-1:0];
            end
         end
      end
   end

   genvar i;
   // Instantiate multipliers
   generate
      for (i=0; i<NUM_MULTIPLIERS; i=i+1) begin : mul
         multiply #(.NUM_ELEMENTS(MUL_NUM_ELEMENTS),
                    .A_BIT_LEN(BIT_LEN),
                    .B_BIT_LEN(BIT_LEN),
                    .WORD_LEN(WORD_LEN)
                   )
            multiply (
                      .clk(clk),
                      .A(mul_A[i]),
                      .B(mul_B[i]),
                      .Cout(mul_cout[i]),
                      .S(mul_s[i])
                     );
      end
   endgenerate

   // Mul output shift register file to gather all results in parallel.
   always_ff @(posedge clk) begin
       if(  (curr_cycle[CYCLE_2] ||
             curr_cycle[CYCLE_3] || 
             curr_cycle[CYCLE_4] || 
             curr_cycle[CYCLE_5] ) ) begin
           mul_reg0_cout <= mul_cout;
           mul_reg1_cout <= mul_reg0_cout;
           mul_reg2_cout <= mul_reg1_cout;
           mul_reg3_cout <= mul_reg2_cout;
           mul_reg0_s    <= mul_s;
           mul_reg1_s    <= mul_reg0_s;
           mul_reg2_s    <= mul_reg1_s;
           mul_reg3_s    <= mul_reg2_s;
       end
   end




   always_comb begin
      // Initialize grid for accumulating multiplier results across columns
      for (int k=0; k<GRID_SIZE; k=k+1) begin
         for (int l=0; l<GRID_NUM_ELEMENTS; l=l+1) begin
            grid[k][l] = '0;
         end
      end
      
      // place multiplier elements into proper grid locations
      // keep same order as orig 8 cycle mult
      // Multiplier output { 1, 0)
      // mul_reg3_s/cout = {DD,CD}, 
      // mul_reg2_s/cout = {DB,CC}, 
      // mul_reg1_s/cout = {CB,DA}, 
      // mul_reg0_s/cout = {BB,CA}, 
      // mul_s/cout      = {AB,AA}, 
      
     for (int k=0; k<(MUL_NUM_ELEMENTS*2); k=k+1) begin
         if( k < ( SEGMENT_ELEMENTS * 2 ) ) begin // 32 word
             // Squared terms are not scaled by 2
             // AA is mul_s/cout[1] , no shift, start at offset 0, row 0123     
             grid[SEGMENT_ELEMENTS*0 + k   ][12] = {{GRID_PAD        {1'b0}},      mul_cout[0][k][WORD_LEN-1   :0       ]};
             grid[SEGMENT_ELEMENTS*0 + k+1 ][13] = {{GRID_PAD_CARRY  {1'b0}},      mul_cout[0][k][MUL_BIT_LEN-1:WORD_LEN]};
             grid[SEGMENT_ELEMENTS*0 + k   ][14] = {{GRID_PAD        {1'b0}},      mul_s   [0][k][WORD_LEN-   1:0       ]};
             grid[SEGMENT_ELEMENTS*0 + k+1 ][15] = {{GRID_PAD_CARRY  {1'b0}},      mul_s   [0][k][MUL_BIT_LEN-1:WORD_LEN]};               
             // BB is mul_reg1_s/cout[1] , no shift, start at offset 2, row 4567     
             grid[SEGMENT_ELEMENTS*2 + k   ][12] = {{GRID_PAD        {1'b0}}, mul_reg0_cout[1][k][WORD_LEN-1   :0       ]};
             grid[SEGMENT_ELEMENTS*2 + k+1 ][13] = {{GRID_PAD_CARRY  {1'b0}}, mul_reg0_cout[1][k][MUL_BIT_LEN-1:WORD_LEN]};
             grid[SEGMENT_ELEMENTS*2 + k   ][14] = {{GRID_PAD        {1'b0}}, mul_reg0_s   [1][k][WORD_LEN-   1:0       ]};
             grid[SEGMENT_ELEMENTS*2 + k+1 ][15] = {{GRID_PAD_CARRY  {1'b0}}, mul_reg0_s   [1][k][MUL_BIT_LEN-1:WORD_LEN]};               
             // CC is mul_reg2_s/cout[0] , no shift, start at offset 4, row 0123
             grid[SEGMENT_ELEMENTS*4 + k   ][12] = {{GRID_PAD        {1'b0}}, mul_reg2_cout[0][k][WORD_LEN-1   :0       ]};
             grid[SEGMENT_ELEMENTS*4 + k+1 ][13] = {{GRID_PAD_CARRY  {1'b0}}, mul_reg2_cout[0][k][MUL_BIT_LEN-1:WORD_LEN]};
             grid[SEGMENT_ELEMENTS*4 + k   ][14] = {{GRID_PAD        {1'b0}}, mul_reg2_s   [0][k][WORD_LEN-   1:0       ]};
             grid[SEGMENT_ELEMENTS*4 + k+1 ][15] = {{GRID_PAD_CARRY  {1'b0}}, mul_reg2_s   [0][k][MUL_BIT_LEN-1:WORD_LEN]};               
             // All other products are scaled by 2 (left shift)
             // AB is      mul_s/cout[1] , shift, start at offset 1, row 0123
             grid[SEGMENT_ELEMENTS*1 + k   ][ 0] = {{GRID_PAD        {1'b0}},      mul_cout[1][k][WORD_LEN-2   :0         ], 1'b0};
             grid[SEGMENT_ELEMENTS*1 + k+1 ][ 1] = {{GRID_PAD_C_SHIFT{1'b0}},      mul_cout[1][k][MUL_BIT_LEN-1:WORD_LEN-1]};
             grid[SEGMENT_ELEMENTS*1 + k   ][ 2] = {{GRID_PAD        {1'b0}},      mul_s   [1][k][WORD_LEN-2   :0         ], 1'b0};
             grid[SEGMENT_ELEMENTS*1 + k+1 ][ 3] = {{GRID_PAD_C_SHIFT{1'b0}},      mul_s   [1][k][MUL_BIT_LEN-1:WORD_LEN-1]};
             // AC is mul_reg0_s/cout[0] , shift, start at offset 2, row 0123
             grid[SEGMENT_ELEMENTS*2 + k   ][ 4] = {{GRID_PAD        {1'b0}}, mul_reg0_cout[0][k][WORD_LEN-2   :0         ], 1'b0};
             grid[SEGMENT_ELEMENTS*2 + k+1 ][ 5] = {{GRID_PAD_C_SHIFT{1'b0}}, mul_reg0_cout[0][k][MUL_BIT_LEN-1:WORD_LEN-1]};
             grid[SEGMENT_ELEMENTS*2 + k   ][ 6] = {{GRID_PAD        {1'b0}}, mul_reg0_s   [0][k][WORD_LEN-2   :0         ], 1'b0};
             grid[SEGMENT_ELEMENTS*2 + k+1 ][ 7] = {{GRID_PAD_C_SHIFT{1'b0}}, mul_reg0_s   [0][k][MUL_BIT_LEN-1:WORD_LEN-1]};
             // BC is mul_reg1_s/cout[1] , shift, start at offset 3, row 4567
             grid[SEGMENT_ELEMENTS*3 + k   ][ 8] = {{GRID_PAD        {1'b0}}, mul_reg1_cout[1][k][WORD_LEN-2   :0         ], 1'b0};
             grid[SEGMENT_ELEMENTS*3 + k+1 ][ 9] = {{GRID_PAD_C_SHIFT{1'b0}}, mul_reg1_cout[1][k][MUL_BIT_LEN-1:WORD_LEN-1]};
             grid[SEGMENT_ELEMENTS*3 + k   ][10] = {{GRID_PAD        {1'b0}}, mul_reg1_s   [1][k][WORD_LEN-2   :0         ], 1'b0};
             grid[SEGMENT_ELEMENTS*3 + k+1 ][11] = {{GRID_PAD_C_SHIFT{1'b0}}, mul_reg1_s   [1][k][MUL_BIT_LEN-1:WORD_LEN-1]};
         end else begin // 36 word
             // Squared terms are not scaled by 2
             // DD is mul_reg3_s/cout[1] , no shift, start at offset 6, row 4567
             grid[SEGMENT_ELEMENTS*6 + k   ][12] = {{GRID_PAD        {1'b0}}, mul_reg3_cout[1][k][WORD_LEN-1   :0       ]};
             grid[SEGMENT_ELEMENTS*6 + k+1 ][13] = {{GRID_PAD_CARRY  {1'b0}}, mul_reg3_cout[1][k][MUL_BIT_LEN-1:WORD_LEN]};
             grid[SEGMENT_ELEMENTS*6 + k   ][14] = {{GRID_PAD        {1'b0}}, mul_reg3_s   [1][k][WORD_LEN-   1:0       ]};
             grid[SEGMENT_ELEMENTS*6 + k+1 ][15] = {{GRID_PAD_CARRY  {1'b0}}, mul_reg3_s   [1][k][MUL_BIT_LEN-1:WORD_LEN]};               
             // All other products are scaled by 2 (left shift)
             // AD is mul_reg1_s/cout[0] , shift, start at offset 3, row 0123
             grid[SEGMENT_ELEMENTS*3 + k   ][ 0] = {{GRID_PAD        {1'b0}}, mul_reg1_cout[0][k][WORD_LEN-2   :0         ], 1'b0};
             grid[SEGMENT_ELEMENTS*3 + k+1 ][ 1] = {{GRID_PAD_C_SHIFT{1'b0}}, mul_reg1_cout[0][k][MUL_BIT_LEN-1:WORD_LEN-1]};
             grid[SEGMENT_ELEMENTS*3 + k   ][ 2] = {{GRID_PAD        {1'b0}}, mul_reg1_s   [0][k][WORD_LEN-2   :0         ], 1'b0};
             grid[SEGMENT_ELEMENTS*3 + k+1 ][ 3] = {{GRID_PAD_C_SHIFT{1'b0}}, mul_reg1_s   [0][k][MUL_BIT_LEN-1:WORD_LEN-1]};
             // BD is mul_reg2_s/cout[1] , shift, start at offset 4, row 4567
             grid[SEGMENT_ELEMENTS*4 + k   ][ 4] = {{GRID_PAD        {1'b0}}, mul_reg2_cout[1][k][WORD_LEN-2   :0         ], 1'b0};
             grid[SEGMENT_ELEMENTS*4 + k+1 ][ 5] = {{GRID_PAD_C_SHIFT{1'b0}}, mul_reg2_cout[1][k][MUL_BIT_LEN-1:WORD_LEN-1]};
             grid[SEGMENT_ELEMENTS*4 + k   ][ 6] = {{GRID_PAD        {1'b0}}, mul_reg2_s   [1][k][WORD_LEN-2   :0         ], 1'b0};
             grid[SEGMENT_ELEMENTS*4 + k+1 ][ 7] = {{GRID_PAD_C_SHIFT{1'b0}}, mul_reg2_s   [1][k][MUL_BIT_LEN-1:WORD_LEN-1]};
             // CD is mul_reg3_s/cout[0] , shift, start at offset 5, row 0123
             grid[SEGMENT_ELEMENTS*5 + k   ][ 8] = {{GRID_PAD        {1'b0}}, mul_reg3_cout[0][k][WORD_LEN-2   :0         ], 1'b0};
             grid[SEGMENT_ELEMENTS*5 + k+1 ][ 9] = {{GRID_PAD_C_SHIFT{1'b0}}, mul_reg3_cout[0][k][MUL_BIT_LEN-1:WORD_LEN-1]};
             grid[SEGMENT_ELEMENTS*5 + k   ][10] = {{GRID_PAD        {1'b0}}, mul_reg3_s   [0][k][WORD_LEN-2   :0         ], 1'b0};
             grid[SEGMENT_ELEMENTS*5 + k+1 ][11] = {{GRID_PAD_C_SHIFT{1'b0}}, mul_reg3_s   [0][k][MUL_BIT_LEN-1:WORD_LEN-1]};
         end
      end
   end

   // Instantiate 8 input compressor trees to accumulate over grid columns
   generate
      for (i=0; i<GRID_SIZE; i=i+1) begin : grid_acc
         compressor_tree_3_to_2 #(.NUM_ELEMENTS(GRID_NUM_ELEMENTS),
                                  .BIT_LEN(GRID_BIT_LEN)
                                 )
            compressor_tree_3_to_2 (
                                    .terms(grid[i]),
                                    .C(C[i]),
                                    .S(S[i])
                                   );
      end
   endgenerate

   // Carry propogate add each column in grid
   // Partially reduce adding neighbor carries
   always_comb begin
      for (int k=0; k<GRID_SIZE; k=k+1) begin
         grid_sum[k][GRID_BIT_LEN:0] = C[k][GRID_BIT_LEN-1:0] + 
                                       S[k][GRID_BIT_LEN-1:0];
      end

      reduced_grid_sum[0] =    {{(BIT_LEN-WORD_LEN)                 {1'b0}}, grid_sum[0][WORD_LEN-1:0]};
      for (int k=1; k<GRID_SIZE-1; k=k+1) begin
         reduced_grid_sum[k] = {{(BIT_LEN-WORD_LEN)                 {1'b0}}, grid_sum[k  ][WORD_LEN-1:0]} +
                               {{(BIT_LEN-(GRID_BIT_LEN-WORD_LEN))-1{1'b0}}, grid_sum[k-1][GRID_BIT_LEN:WORD_LEN]};
      end
      reduced_grid_sum[GRID_SIZE-1] = grid_sum[GRID_SIZE-1][BIT_LEN-1:0] +
                               {{(BIT_LEN-(GRID_BIT_LEN-WORD_LEN))-1{1'b0}}, grid_sum[GRID_SIZE-2][GRID_BIT_LEN:WORD_LEN]};
   end
   
   always_ff @(posedge clk) begin
      if (curr_cycle[CYCLE_7]) begin
         reduced_grid_reg <= reduced_grid_sum;
      end
   end
   


   // Set values for which segments to lookup in reduction LUTs
   always_comb begin
      for (int k=0; k<ACC_ELEMENTS; k=k+1) begin
         lut_addr0[k][LOOK_UP_WIDTH-1:0] = { 1'b0, reduced_grid_sum[k+64][ LOOK_UP_WIDTH-1    : 0            ]}; // LBSs of lower words
         lut_addr1[k][LOOK_UP_WIDTH-1:0] = { 1'b0, reduced_grid_sum[k+64][(LOOK_UP_WIDTH*2)-1 : LOOK_UP_WIDTH]}; // MSB of lower words
         lut_addr2[k][LOOK_UP_WIDTH-1:0] = { 1'b1, reduced_grid_sum[k+96][ LOOK_UP_WIDTH-1    : 0            ]}; // LSB of Upper words
         lut_addr3[k][LOOK_UP_WIDTH-1:0] = { 1'b1, reduced_grid_sum[k+96][(LOOK_UP_WIDTH*2)-1 : LOOK_UP_WIDTH]}; // MSB of upper words
         lut_addr4[k][LOOK_UP_WIDTH-1:0] = { 8'b0, reduced_grid_sum[k+64][(LOOK_UP_WIDTH*2)]};             // OVF of lower words
         lut_addr5[k][LOOK_UP_WIDTH-1:0] = { 8'b0, reduced_grid_sum[k+96][(LOOK_UP_WIDTH*2)]};             // OVF of upper words
      end
   end
   
   // Instantiate memory holding reduction LUTs
   // TODO - remove reduction loading pins or drive them
   /* verilator lint_off PINMISSING */
   wire lut_sel = curr_cycle[CYCLE_7];
   reduction_lut #(.REDUNDANT_ELEMENTS(REDUNDANT_ELEMENTS),
                   .NONREDUNDANT_ELEMENTS(NONREDUNDANT_ELEMENTS),
                   .NUM_SEGMENTS(NUM_SEGMENTS),
                   .WORD_LEN(WORD_LEN)
                  )
      reduction_lut_54 (
                     .clk(clk),
                     .shift_high( lut_sel ), 
                     .shift_overflow(1'b00),
                     .lut_addr( (lut_sel) ? lut_addr1 : lut_addr0 ),
                     .lut_data(lut_data1),
                     .we(0)
                    );
   reduction_lut #(.REDUNDANT_ELEMENTS(REDUNDANT_ELEMENTS),
                   .NONREDUNDANT_ELEMENTS(NONREDUNDANT_ELEMENTS),
                   .NUM_SEGMENTS(NUM_SEGMENTS),
                   .WORD_LEN(WORD_LEN)
                  )
      reduction_lut_76 (
                     .clk(clk),
                     .shift_high( lut_sel ), // Upper
                     .shift_overflow(1'b0),
                     .lut_addr( (lut_sel) ? lut_addr3 : lut_addr2),
                     .lut_data(lut_data3),
                     .we(0)
                    );
   reduction_lut #(.REDUNDANT_ELEMENTS(REDUNDANT_ELEMENTS),
                   .NONREDUNDANT_ELEMENTS(NONREDUNDANT_ELEMENTS),
                   .NUM_SEGMENTS(NUM_SEGMENTS),
                   .WORD_LEN(WORD_LEN)
                  )
      reduction_lut_ovf54 (
                     .clk(clk),
                     .shift_high( 1'b0 ), 
                     .shift_overflow(1'b1),
                     .lut_addr( lut_addr4 ),
                     .lut_data( lut_data4 ),
                     .we(0)
                    );
   reduction_lut #(.REDUNDANT_ELEMENTS(REDUNDANT_ELEMENTS),
                   .NONREDUNDANT_ELEMENTS(NONREDUNDANT_ELEMENTS),
                   .NUM_SEGMENTS(NUM_SEGMENTS),
                   .WORD_LEN(WORD_LEN)
                  )
      reduction_lut_ovf76 (
                     .clk(clk),
                     .shift_high( 1'b0 ),
                     .shift_overflow(1'b1),
                     .lut_addr( lut_addr5 ),
                     .lut_data( lut_data5 ),
                     .we(0)
                    );
   /* verilator lint_on PINMISSING */
   always_ff @(posedge clk) begin
      if (curr_cycle[CYCLE_7]) begin
         lut_data0 <= lut_data1;
         lut_data2 <= lut_data3;       
      end
   end
   // Accumulate reduction lut values with running total
   always_comb begin
      for (int k=0; k<NUM_ELEMENTS; k=k+1) begin
         for (int j=0; j<ACC_ELEMENTS; j=j+1) begin
            if( j < 2*SEGMENT_ELEMENTS ) begin
                // V54[32\
                acc_stack[k][j+0*2*SEGMENT_ELEMENTS][ACC_BIT_LEN-1:0] = {{ACC_EXTRA_BIT_LEN{1'b0}}, lut_data0[k][j][BIT_LEN-1:0]};
                acc_stack[k][j+1*2*SEGMENT_ELEMENTS][ACC_BIT_LEN-1:0] = {{ACC_EXTRA_BIT_LEN{1'b0}}, lut_data1[k][j][BIT_LEN-1:0]};
                acc_stack[k][j+2*2*SEGMENT_ELEMENTS][ACC_BIT_LEN-1:0] = {{ACC_EXTRA_BIT_LEN{1'b0}}, lut_data4[k][j][BIT_LEN-1:0]};
                // V76[36]
                acc_stack[k][j+3*2*SEGMENT_ELEMENTS+0*ACC_ELEMENTS][ACC_BIT_LEN-1:0] = {{ACC_EXTRA_BIT_LEN{1'b0}}, lut_data2[k][j][BIT_LEN-1:0]};
                acc_stack[k][j+3*2*SEGMENT_ELEMENTS+1*ACC_ELEMENTS][ACC_BIT_LEN-1:0] = {{ACC_EXTRA_BIT_LEN{1'b0}}, lut_data3[k][j][BIT_LEN-1:0]};
                acc_stack[k][j+3*2*SEGMENT_ELEMENTS+2*ACC_ELEMENTS][ACC_BIT_LEN-1:0] = {{ACC_EXTRA_BIT_LEN{1'b0}}, lut_data5[k][j][BIT_LEN-1:0]};
            end else begin
                acc_stack[k][j+3*2*SEGMENT_ELEMENTS+0*ACC_ELEMENTS][ACC_BIT_LEN-1:0] = {{ACC_EXTRA_BIT_LEN{1'b0}}, lut_data2[k][j][BIT_LEN-1:0]};
                acc_stack[k][j+3*2*SEGMENT_ELEMENTS+1*ACC_ELEMENTS][ACC_BIT_LEN-1:0] = {{ACC_EXTRA_BIT_LEN{1'b0}}, lut_data3[k][j][BIT_LEN-1:0]};
                acc_stack[k][j+3*2*SEGMENT_ELEMENTS+2*ACC_ELEMENTS][ACC_BIT_LEN-1:0] = {{ACC_EXTRA_BIT_LEN{1'b0}}, lut_data5[k][j][BIT_LEN-1:0]};
            end
         end
         acc_stack[k][3*2*SEGMENT_ELEMENTS+3*ACC_ELEMENTS][ACC_BIT_LEN-1:0] = {{ACC_EXTRA_BIT_LEN{1'b0}}, reduced_grid_reg[k][BIT_LEN-1:0]};
      end
   end

   // Instantiate compressor trees to accumulate over accumulator columns
   generate
      for (i=0; i<NUM_ELEMENTS; i=i+1) begin : final_acc
         compressor_tree_3_to_2 #(.NUM_ELEMENTS(3*2*SEGMENT_ELEMENTS+3*ACC_ELEMENTS+ACC_EXTRA_ELEMENTS),
                                  .BIT_LEN(ACC_BIT_LEN)
                                 )
            compressor_tree_3_to_2 (
                                    .terms(acc_stack[i]),
                                    .C(acc_C[i]),
                                    .S(acc_S[i])
                                   );
      end
   endgenerate

   // Carry propogate add each column in accumulator result
   // Partially reduce adding neighbor carries
   always_comb begin
      for (int k=0; k<NUM_ELEMENTS; k=k+1) begin
         acc_sum[k][ACC_BIT_LEN:0] = acc_C[k][ACC_BIT_LEN-1:0] +
                                     acc_S[k][ACC_BIT_LEN-1:0];
      end

      reduced_acc_sum[0] =     {{(BIT_LEN-WORD_LEN)                {1'b0}}, acc_sum[0  ][WORD_LEN-1:0]};
      for (int k=1; k<NUM_ELEMENTS-1; k=k+1) begin
         reduced_acc_sum[k] =  {{(BIT_LEN-WORD_LEN)                {1'b0}}, acc_sum[k  ][WORD_LEN-1:0]} +
                               {{(BIT_LEN-(ACC_BIT_LEN-WORD_LEN))-1{1'b0}}, acc_sum[k-1][ACC_BIT_LEN:WORD_LEN]};
      end
      reduced_acc_sum[NUM_ELEMENTS-1] = acc_sum[NUM_ELEMENTS-1][BIT_LEN-1:0] +
                               {{(BIT_LEN-(ACC_BIT_LEN-WORD_LEN))-1{1'b0}}, acc_sum[NUM_ELEMENTS-2][ACC_BIT_LEN:WORD_LEN]};
   end

   // Flop output
   always_ff @(posedge clk) begin
      if ( curr_cycle[CYCLE_8] ) begin
        for (int k=0; k<(NUM_ELEMENTS); k=k+1) begin
            sq_out[k][BIT_LEN-1:0]      <= reduced_acc_sum[k][BIT_LEN-1:0];
        end
      end
   end
endmodule
