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
   wire  [BIT_LEN-1:0]       lut_data0[NUM_ELEMENTS][ACC_ELEMENTS];
   logic [LOOK_UP_WIDTH:0]   lut_addr1[ACC_ELEMENTS];
   reg   [BIT_LEN-1:0]       lut_data1[NUM_ELEMENTS][ACC_ELEMENTS];
   logic [LOOK_UP_WIDTH:0]   lut_addr2[ACC_ELEMENTS];
   wire  [BIT_LEN-1:0]       lut_data2[NUM_ELEMENTS][ACC_ELEMENTS];
   logic [LOOK_UP_WIDTH:0]   lut_addr3[ACC_ELEMENTS];
   reg   [BIT_LEN-1:0]       lut_data3[NUM_ELEMENTS][ACC_ELEMENTS];




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
         reduced_grid_reg <= reduced_grid_sum;
   end
   


   // Set values for which segments to lookup in reduction LUTs
   always_comb begin
      for (int k=0; k<ACC_ELEMENTS; k=k+1) begin
         lut_addr0[k][LOOK_UP_WIDTH:0] = { 1'b0, reduced_grid_sum[k+64][ LOOK_UP_WIDTH-1    : 0            ]}; // LBS8 of lower V54 words
         lut_addr1[k][LOOK_UP_WIDTH:0] = {       reduced_grid_sum[k+64][(LOOK_UP_WIDTH*2)   : LOOK_UP_WIDTH]}; // MSB9 of lower V54 words
         lut_addr2[k][LOOK_UP_WIDTH:0] = { 1'b0, reduced_grid_sum[k+96][ LOOK_UP_WIDTH-1    : 0            ]}; // LSB8 of Upper V76 words
         lut_addr3[k][LOOK_UP_WIDTH:0] = {       reduced_grid_sum[k+96][(LOOK_UP_WIDTH*2)   : LOOK_UP_WIDTH]}; // MSB9 of upper V76 words
      end
   end
   
   // Instantiate memory holding reduction LUTs
   // TODO - remove reduction loading pins or drive them
   /* verilator lint_off PINMISSING */

   reduction_lut_full #(.REDUNDANT_ELEMENTS(REDUNDANT_ELEMENTS),
                   .NONREDUNDANT_ELEMENTS(NONREDUNDANT_ELEMENTS),
                   .NUM_SEGMENTS(NUM_SEGMENTS),
                   .WORD_LEN(WORD_LEN)
                  )
      reduction_lut_ (
                     .clk(clk),
                     .shift_high(   curr_cycle[CYCLE_6] ),
                     .lut54_addr( ( curr_cycle[CYCLE_6] ) ? lut_addr1 : lut_addr0 ),
                     .lut76_addr( ( curr_cycle[CYCLE_6] ) ? lut_addr3 : lut_addr2 ),
                     .lut54_data( lut_data0 ),
                     .lut76_data( lut_data2 ),
                     .we(0)
                    );
   /* verilator lint_on PINMISSING */
   // Accumulate reduction lut values with running total
   
   always_ff @(posedge clk) begin
      if ( curr_cycle[CYCLE_7] ) begin
        lut_data1 <= lut_data0;
        lut_data3 <= lut_data2;
      end
   end

   
   always_comb begin
      for (int k=0; k<NUM_ELEMENTS; k=k+1) begin
         for (int j=0; j<ACC_ELEMENTS; j=j+1) begin
            if( j < 2*SEGMENT_ELEMENTS ) begin
                // V54[32]
                acc_stack[k][j+0*2*SEGMENT_ELEMENTS][ACC_BIT_LEN-1:0] = {{ACC_EXTRA_BIT_LEN{1'b0}}, lut_data0[k][j][BIT_LEN-1:0]};
                acc_stack[k][j+1*2*SEGMENT_ELEMENTS][ACC_BIT_LEN-1:0] = {{ACC_EXTRA_BIT_LEN{1'b0}}, lut_data1[k][j][BIT_LEN-1:0]};
                // V76[36]
                acc_stack[k][j+2*2*SEGMENT_ELEMENTS+0*ACC_ELEMENTS][ACC_BIT_LEN-1:0] = {{ACC_EXTRA_BIT_LEN{1'b0}}, lut_data2[k][j][BIT_LEN-1:0]};
                acc_stack[k][j+2*2*SEGMENT_ELEMENTS+1*ACC_ELEMENTS][ACC_BIT_LEN-1:0] = {{ACC_EXTRA_BIT_LEN{1'b0}}, lut_data3[k][j][BIT_LEN-1:0]};
            end else begin
                acc_stack[k][j+2*2*SEGMENT_ELEMENTS+0*ACC_ELEMENTS][ACC_BIT_LEN-1:0] = {{ACC_EXTRA_BIT_LEN{1'b0}}, lut_data2[k][j][BIT_LEN-1:0]};
                acc_stack[k][j+2*2*SEGMENT_ELEMENTS+1*ACC_ELEMENTS][ACC_BIT_LEN-1:0] = {{ACC_EXTRA_BIT_LEN{1'b0}}, lut_data3[k][j][BIT_LEN-1:0]};
            end
         end
         acc_stack[k][3*2*SEGMENT_ELEMENTS+3*ACC_ELEMENTS][ACC_BIT_LEN-1:0] = {{ACC_EXTRA_BIT_LEN{1'b0}}, reduced_grid_reg[k][BIT_LEN-1:0]};
      end
   end

   // Instantiate compressor trees to accumulate over accumulator columns
   generate
      for (i=0; i<NUM_ELEMENTS; i=i+1) begin : final_acc
         compressor_tree_3_to_2 #(.NUM_ELEMENTS(2*2*SEGMENT_ELEMENTS+2*ACC_ELEMENTS+ACC_EXTRA_ELEMENTS),
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


/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

module reduction_lut_full
   #(
     parameter int REDUNDANT_ELEMENTS    = 2,
     parameter int NONREDUNDANT_ELEMENTS = 64,
     parameter int NUM_SEGMENTS          = 4,
     parameter int WORD_LEN              = 16,
     parameter int BIT_LEN               = 17,
     parameter int DIN_LEN               = 8,

     parameter int NUM_ELEMENTS          = REDUNDANT_ELEMENTS+
                                           NONREDUNDANT_ELEMENTS,
     parameter int LOOK_UP_WIDTH         = int'(WORD_LEN / 2),
     parameter int SEGMENT_ELEMENTS      = int'(NONREDUNDANT_ELEMENTS /
                                                 NUM_SEGMENTS),
     parameter int EXTRA_ELEMENTS        = 2,
     parameter int LUT_NUM_ELEMENTS      = REDUNDANT_ELEMENTS+EXTRA_ELEMENTS+
                                           (SEGMENT_ELEMENTS*2)

    )
   (
    input  logic                     clk,
    input  logic                     shift_high,  // Applies to both LUTs
    input  logic [LOOK_UP_WIDTH:0]   lut54_addr[LUT_NUM_ELEMENTS], // V54 [7:0]
    input  logic [LOOK_UP_WIDTH:0]   lut76_addr[LUT_NUM_ELEMENTS], // V54 [16:8]
    output logic [BIT_LEN-1:0]       lut54_data[NUM_ELEMENTS][LUT_NUM_ELEMENTS],
    output logic [BIT_LEN-1:0]       lut76_data[NUM_ELEMENTS][LUT_NUM_ELEMENTS],
/* verilator lint_off UNUSED */
    input                            we,
    input [DIN_LEN-1:0]              din,
    input                            din_valid
/* verilator lint_on UNUSED */
   );

   // 9 bit lookups
   localparam int NUM_LUT_ENTRIES   = 2**(LOOK_UP_WIDTH+1);
   localparam int LUT_WIDTH         = WORD_LEN * NONREDUNDANT_ELEMENTS;

   localparam int NUM_BRAM          = LUT_NUM_ELEMENTS;

   logic [LUT_WIDTH-1:0]  lut54_read_data[LUT_NUM_ELEMENTS];
   logic [LUT_WIDTH-1:0]  lut76_read_data[LUT_NUM_ELEMENTS];
   logic [LUT_WIDTH-1:0]  lut54_read_data_bram[NUM_BRAM];
   logic [LUT_WIDTH-1:0]  lut76_read_data_bram[NUM_BRAM];
   logic [BIT_LEN-1:0]    lut54_output[NUM_ELEMENTS][LUT_NUM_ELEMENTS];
   logic [BIT_LEN-1:0]    lut76_output[NUM_ELEMENTS][LUT_NUM_ELEMENTS];


   // Delay to align with data from memory
   logic shift_high_1d;

   always_ff @(posedge clk) begin
      shift_high_1d     <= shift_high;
   end

   // Delay to align with data from memory
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut54_000[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut54_001[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut54_002[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut54_003[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut54_004[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut54_005[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut54_006[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut54_007[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut54_008[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut54_009[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut54_010[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut54_011[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut54_012[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut54_013[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut54_014[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut54_015[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut54_016[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut54_017[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut54_018[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut54_019[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut54_020[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut54_021[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut54_022[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut54_023[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut54_024[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut54_025[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut54_026[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut54_027[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut54_028[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut54_029[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut54_030[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut54_031[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut54_032[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut54_033[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut54_034[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut54_035[NUM_LUT_ENTRIES];

   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut76_000[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut76_001[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut76_002[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut76_003[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut76_004[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut76_005[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut76_006[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut76_007[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut76_008[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut76_009[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut76_010[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut76_011[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut76_012[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut76_013[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut76_014[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut76_015[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut76_016[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut76_017[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut76_018[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut76_019[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut76_020[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut76_021[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut76_022[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut76_023[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut76_024[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut76_025[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut76_026[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut76_027[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut76_028[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut76_029[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut76_030[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut76_031[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut76_032[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut76_033[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut76_034[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut76_035[NUM_LUT_ENTRIES];

   initial begin
      $readmemh("reduction_lut_54_000.dat", lut54_000);
      $readmemh("reduction_lut_54_001.dat", lut54_001);
      $readmemh("reduction_lut_54_002.dat", lut54_002);
      $readmemh("reduction_lut_54_003.dat", lut54_003);
      $readmemh("reduction_lut_54_004.dat", lut54_004);
      $readmemh("reduction_lut_54_005.dat", lut54_005);
      $readmemh("reduction_lut_54_006.dat", lut54_006);
      $readmemh("reduction_lut_54_007.dat", lut54_007);
      $readmemh("reduction_lut_54_008.dat", lut54_008);
      $readmemh("reduction_lut_54_009.dat", lut54_009);
      $readmemh("reduction_lut_54_010.dat", lut54_010);
      $readmemh("reduction_lut_54_011.dat", lut54_011);
      $readmemh("reduction_lut_54_012.dat", lut54_012);
      $readmemh("reduction_lut_54_013.dat", lut54_013);
      $readmemh("reduction_lut_54_014.dat", lut54_014);
      $readmemh("reduction_lut_54_015.dat", lut54_015);
      $readmemh("reduction_lut_54_016.dat", lut54_016);
      $readmemh("reduction_lut_54_017.dat", lut54_017);
      $readmemh("reduction_lut_54_018.dat", lut54_018);
      $readmemh("reduction_lut_54_019.dat", lut54_019);
      $readmemh("reduction_lut_54_020.dat", lut54_020);
      $readmemh("reduction_lut_54_021.dat", lut54_021);
      $readmemh("reduction_lut_54_022.dat", lut54_022);
      $readmemh("reduction_lut_54_023.dat", lut54_023);
      $readmemh("reduction_lut_54_024.dat", lut54_024);
      $readmemh("reduction_lut_54_025.dat", lut54_025);
      $readmemh("reduction_lut_54_026.dat", lut54_026);
      $readmemh("reduction_lut_54_027.dat", lut54_027);
      $readmemh("reduction_lut_54_028.dat", lut54_028);
      $readmemh("reduction_lut_54_029.dat", lut54_029);
      $readmemh("reduction_lut_54_030.dat", lut54_030);
      $readmemh("reduction_lut_54_031.dat", lut54_031);
      $readmemh("reduction_lut_54_032.dat", lut54_032);
      $readmemh("reduction_lut_54_033.dat", lut54_033);
      $readmemh("reduction_lut_54_034.dat", lut54_034);
      $readmemh("reduction_lut_54_035.dat", lut54_035);

      $readmemh("reduction_lut_54_000.dat", lut76_000);
      $readmemh("reduction_lut_54_001.dat", lut76_001);
      $readmemh("reduction_lut_54_002.dat", lut76_002);
      $readmemh("reduction_lut_54_003.dat", lut76_003);
      $readmemh("reduction_lut_54_004.dat", lut76_004);
      $readmemh("reduction_lut_54_005.dat", lut76_005);
      $readmemh("reduction_lut_54_006.dat", lut76_006);
      $readmemh("reduction_lut_54_007.dat", lut76_007);
      $readmemh("reduction_lut_54_008.dat", lut76_008);
      $readmemh("reduction_lut_54_009.dat", lut76_009);
      $readmemh("reduction_lut_54_010.dat", lut76_010);
      $readmemh("reduction_lut_54_011.dat", lut76_011);
      $readmemh("reduction_lut_54_012.dat", lut76_012);
      $readmemh("reduction_lut_54_013.dat", lut76_013);
      $readmemh("reduction_lut_54_014.dat", lut76_014);
      $readmemh("reduction_lut_54_015.dat", lut76_015);
      $readmemh("reduction_lut_54_016.dat", lut76_016);
      $readmemh("reduction_lut_54_017.dat", lut76_017);
      $readmemh("reduction_lut_54_018.dat", lut76_018);
      $readmemh("reduction_lut_54_019.dat", lut76_019);
      $readmemh("reduction_lut_54_020.dat", lut76_020);
      $readmemh("reduction_lut_54_021.dat", lut76_021);
      $readmemh("reduction_lut_54_022.dat", lut76_022);
      $readmemh("reduction_lut_54_023.dat", lut76_023);
      $readmemh("reduction_lut_54_024.dat", lut76_024);
      $readmemh("reduction_lut_54_025.dat", lut76_025);
      $readmemh("reduction_lut_54_026.dat", lut76_026);
      $readmemh("reduction_lut_54_027.dat", lut76_027);
      $readmemh("reduction_lut_54_028.dat", lut76_028);
      $readmemh("reduction_lut_54_029.dat", lut76_029);
      $readmemh("reduction_lut_54_030.dat", lut76_030);
      $readmemh("reduction_lut_54_031.dat", lut76_031);
      $readmemh("reduction_lut_54_032.dat", lut76_032);
      $readmemh("reduction_lut_54_033.dat", lut76_033);
      $readmemh("reduction_lut_54_034.dat", lut76_034);
      $readmemh("reduction_lut_54_035.dat", lut76_035);

   end

   always_ff @(posedge clk) begin
      lut54_read_data_bram[0]  <= lut54_000[lut54_addr[0]];
      lut54_read_data_bram[1]  <= lut54_001[lut54_addr[1]];
      lut54_read_data_bram[2]  <= lut54_002[lut54_addr[2]];
      lut54_read_data_bram[3]  <= lut54_003[lut54_addr[3]];
      lut54_read_data_bram[4]  <= lut54_004[lut54_addr[4]];
      lut54_read_data_bram[5]  <= lut54_005[lut54_addr[5]];
      lut54_read_data_bram[6]  <= lut54_006[lut54_addr[6]];
      lut54_read_data_bram[7]  <= lut54_007[lut54_addr[7]];
      lut54_read_data_bram[8]  <= lut54_008[lut54_addr[8]];
      lut54_read_data_bram[9]  <= lut54_009[lut54_addr[9]];
      lut54_read_data_bram[10] <= lut54_010[lut54_addr[10]];
      lut54_read_data_bram[11] <= lut54_011[lut54_addr[11]];
      lut54_read_data_bram[12] <= lut54_012[lut54_addr[12]];
      lut54_read_data_bram[13] <= lut54_013[lut54_addr[13]];
      lut54_read_data_bram[14] <= lut54_014[lut54_addr[14]];
      lut54_read_data_bram[15] <= lut54_015[lut54_addr[15]];
      lut54_read_data_bram[16] <= lut54_016[lut54_addr[16]];
      lut54_read_data_bram[17] <= lut54_017[lut54_addr[17]];
      lut54_read_data_bram[18] <= lut54_018[lut54_addr[18]];
      lut54_read_data_bram[19] <= lut54_019[lut54_addr[19]];
      lut54_read_data_bram[20] <= lut54_020[lut54_addr[20]];
      lut54_read_data_bram[21] <= lut54_021[lut54_addr[21]];
      lut54_read_data_bram[22] <= lut54_022[lut54_addr[22]];
      lut54_read_data_bram[23] <= lut54_023[lut54_addr[23]];
      lut54_read_data_bram[24] <= lut54_024[lut54_addr[24]];
      lut54_read_data_bram[25] <= lut54_025[lut54_addr[25]];
      lut54_read_data_bram[26] <= lut54_026[lut54_addr[26]];
      lut54_read_data_bram[27] <= lut54_027[lut54_addr[27]];
      lut54_read_data_bram[28] <= lut54_028[lut54_addr[28]];
      lut54_read_data_bram[29] <= lut54_029[lut54_addr[29]];
      lut54_read_data_bram[30] <= lut54_030[lut54_addr[30]];
      lut54_read_data_bram[31] <= lut54_031[lut54_addr[31]];
      lut54_read_data_bram[32] <= lut54_032[lut54_addr[32]];
      lut54_read_data_bram[33] <= lut54_033[lut54_addr[33]];
      lut54_read_data_bram[34] <= lut54_034[lut54_addr[34]];
      lut54_read_data_bram[35] <= lut54_035[lut54_addr[35]];

      lut76_read_data_bram[0]  <= lut76_000[lut76_addr[0]];
      lut76_read_data_bram[1]  <= lut76_001[lut76_addr[1]];
      lut76_read_data_bram[2]  <= lut76_002[lut76_addr[2]];
      lut76_read_data_bram[3]  <= lut76_003[lut76_addr[3]];
      lut76_read_data_bram[4]  <= lut76_004[lut76_addr[4]];
      lut76_read_data_bram[5]  <= lut76_005[lut76_addr[5]];
      lut76_read_data_bram[6]  <= lut76_006[lut76_addr[6]];
      lut76_read_data_bram[7]  <= lut76_007[lut76_addr[7]];
      lut76_read_data_bram[8]  <= lut76_008[lut76_addr[8]];
      lut76_read_data_bram[9]  <= lut76_009[lut76_addr[9]];
      lut76_read_data_bram[10] <= lut76_010[lut76_addr[10]];
      lut76_read_data_bram[11] <= lut76_011[lut76_addr[11]];
      lut76_read_data_bram[12] <= lut76_012[lut76_addr[12]];
      lut76_read_data_bram[13] <= lut76_013[lut76_addr[13]];
      lut76_read_data_bram[14] <= lut76_014[lut76_addr[14]];
      lut76_read_data_bram[15] <= lut76_015[lut76_addr[15]];
      lut76_read_data_bram[16] <= lut76_016[lut76_addr[16]];
      lut76_read_data_bram[17] <= lut76_017[lut76_addr[17]];
      lut76_read_data_bram[18] <= lut76_018[lut76_addr[18]];
      lut76_read_data_bram[19] <= lut76_019[lut76_addr[19]];
      lut76_read_data_bram[20] <= lut76_020[lut76_addr[20]];
      lut76_read_data_bram[21] <= lut76_021[lut76_addr[21]];
      lut76_read_data_bram[22] <= lut76_022[lut76_addr[22]];
      lut76_read_data_bram[23] <= lut76_023[lut76_addr[23]];
      lut76_read_data_bram[24] <= lut76_024[lut76_addr[24]];
      lut76_read_data_bram[25] <= lut76_025[lut76_addr[25]];
      lut76_read_data_bram[26] <= lut76_026[lut76_addr[26]];
      lut76_read_data_bram[27] <= lut76_027[lut76_addr[27]];
      lut76_read_data_bram[28] <= lut76_028[lut76_addr[28]];
      lut76_read_data_bram[29] <= lut76_029[lut76_addr[29]];
      lut76_read_data_bram[30] <= lut76_030[lut76_addr[30]];
      lut76_read_data_bram[31] <= lut76_031[lut76_addr[31]];
      lut76_read_data_bram[32] <= lut76_032[lut76_addr[32]];
      lut76_read_data_bram[33] <= lut76_033[lut76_addr[33]];
      lut76_read_data_bram[34] <= lut76_034[lut76_addr[34]];
      lut76_read_data_bram[35] <= lut76_035[lut76_addr[35]];
   end

   // Read data out of the memories
   always_comb begin
      for (int k=0; k<NUM_BRAM; k=k+1) begin
         lut54_read_data[k] = lut54_read_data_bram[k];
         lut76_read_data[k] = lut76_read_data_bram[k];
      end      
   end

   always_comb begin
      // default all outputs 
      for (int k=0; k<LUT_NUM_ELEMENTS; k=k+1) begin
         for (int l=0; l<NUM_ELEMENTS; l=l+1) begin
            lut54_output[l][k] = '0;
            lut76_output[l][k] = '0;
         end
      end
      for (int k=0; k<LUT_NUM_ELEMENTS; k=k+1) begin
         for (int l=0; l<NONREDUNDANT_ELEMENTS+1; l=l+1) begin
            if (shift_high_1d) begin
                if (l == 0) begin
                   lut54_output[l][k][LOOK_UP_WIDTH-1:0] = '0;
                   lut76_output[l][k][LOOK_UP_WIDTH-1:0] = '0;
                end else begin
                   lut54_output[l][k][LOOK_UP_WIDTH-1:0] = lut54_read_data[k][((l-1)*WORD_LEN)+LOOK_UP_WIDTH+:LOOK_UP_WIDTH];
                   lut76_output[l][k][LOOK_UP_WIDTH-1:0] = lut76_read_data[k][((l-1)*WORD_LEN)+LOOK_UP_WIDTH+:LOOK_UP_WIDTH];
                end
            end else begin            
              if (l < NONREDUNDANT_ELEMENTS) begin
                   lut54_output[l][k] = {{(BIT_LEN-WORD_LEN){1'b0}}, lut54_read_data[k][(l*WORD_LEN)+:WORD_LEN]};
                   lut76_output[l][k] = {{(BIT_LEN-WORD_LEN){1'b0}}, lut76_read_data[k][(l*WORD_LEN)+:WORD_LEN]};
              end
            end
         end
      end
   end

   // Need above loops in combo block for Verilator to process
   always_comb begin
      lut54_data  = lut54_output;
      lut76_data  = lut76_output;
   end
endmodule

