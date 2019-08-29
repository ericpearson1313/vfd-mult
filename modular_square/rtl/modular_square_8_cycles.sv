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
   logic [LOOK_UP_WIDTH-1:0] lut_addr0[ACC_ELEMENTS];
   wire  [BIT_LEN-1:0]       lut_data0[NUM_ELEMENTS][ACC_ELEMENTS];
   logic [LOOK_UP_WIDTH-1:0] lut_addr1[ACC_ELEMENTS];
   wire  [BIT_LEN-1:0]       lut_data1[NUM_ELEMENTS][ACC_ELEMENTS];
   logic [LOOK_UP_WIDTH-1:0] lut_addr2[ACC_ELEMENTS];
   wire  [BIT_LEN-1:0]       lut_data2[NUM_ELEMENTS][ACC_ELEMENTS];
   logic [LOOK_UP_WIDTH-1:0] lut_addr3[ACC_ELEMENTS];
   wire  [BIT_LEN-1:0]       lut_data3[NUM_ELEMENTS][ACC_ELEMENTS];
   logic [0:0]               lut_addr4[ACC_ELEMENTS];
   wire  [BIT_LEN-1:0]       lut_data4[NUM_ELEMENTS][ACC_ELEMENTS];
   logic [0:0]               lut_addr5[ACC_ELEMENTS];
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
         lut_addr0[k][LOOK_UP_WIDTH-1:0] = { reduced_grid_sum[k+64][ LOOK_UP_WIDTH-1    : 0            ]}; // LBSs of lower words
         lut_addr1[k][LOOK_UP_WIDTH-1:0] = { reduced_grid_sum[k+64][(LOOK_UP_WIDTH*2)-1 : LOOK_UP_WIDTH]}; // MSB of lower words
         lut_addr2[k][LOOK_UP_WIDTH-1:0] = { reduced_grid_sum[k+96][ LOOK_UP_WIDTH-1    : 0            ]}; // LSB of Upper words
         lut_addr3[k][LOOK_UP_WIDTH-1:0] = { reduced_grid_sum[k+96][(LOOK_UP_WIDTH*2)-1 : LOOK_UP_WIDTH]}; // MSB of upper words
         lut_addr4[k][LOOK_UP_WIDTH-1:0] = { reduced_grid_sum[k+64][(LOOK_UP_WIDTH*2)]};             // OVF of lower words
         lut_addr5[k][LOOK_UP_WIDTH-1:0] = { reduced_grid_sum[k+96][(LOOK_UP_WIDTH*2)]};             // OVF of upper words
      end
   end
   
   // Instantiate memory holding reduction LUTs
   // TODO - remove reduction loading pins or drive them
   /* verilator lint_off PINMISSING */
   wire lut_sel = curr_cycle[CYCLE_7];
   reduction_lut_full #(.REDUNDANT_ELEMENTS(REDUNDANT_ELEMENTS),
                   .NONREDUNDANT_ELEMENTS(NONREDUNDANT_ELEMENTS),
                   .NUM_SEGMENTS(NUM_SEGMENTS),
                   .WORD_LEN(WORD_LEN)
                  )
      reduction_lut_ (
                     .clk(clk),
                     .lut_addr0( lut_addr0 ),
                     .lut_addr1( lut_addr1 ),
                     .lut_addr2( lut_addr2 ),
                     .lut_addr3( lut_addr3 ),
                     .lut_addr4( lut_addr4 ),
                     .lut_addr5( lut_addr5 ),
                     .lut_data0( lut_data0 ),
                     .lut_data1( lut_data1 ),
                     .lut_data2( lut_data2 ),
                     .lut_data3( lut_data3 ),
                     .lut_data4( lut_data4 ),
                     .lut_data5( lut_data5 ),
                     .we(0)
                    );
   /* verilator lint_on PINMISSING */
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


/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

module reduction_lut_full
   #(
     parameter int REDUNDANT_ELEMENTS    = 2,
     parameter int NONREDUNDANT_ELEMENTS = 8,
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
    input  logic                    clk,
    input  logic [LOOK_UP_WIDTH:0]  lut0_addr[LUT_NUM_ELEMENTS], // V54 [7:0]
    input  logic [LOOK_UP_WIDTH:0]  lut1_addr[LUT_NUM_ELEMENTS], // V54 [15:8]
    input  logic [LOOK_UP_WIDTH:0]  lut2_addr[LUT_NUM_ELEMENTS], // V76 [7:0]
    input  logic [LOOK_UP_WIDTH:0]  lut3_addr[LUT_NUM_ELEMENTS], // V76 [15:8]
    input  logic [0:0]              lut4_addr[LUT_NUM_ELEMENTS], // V54 [16] overflow bit
    input  logic [0:0]              lut5_addr[LUT_NUM_ELEMENTS], // V76 [16] overflow bit
    output logic [BIT_LEN-1:0]      lut0_data[NUM_ELEMENTS][LUT_NUM_ELEMENTS],
    output logic [BIT_LEN-1:0]      lut1_data[NUM_ELEMENTS][LUT_NUM_ELEMENTS],
    output logic [BIT_LEN-1:0]      lut2_data[NUM_ELEMENTS][LUT_NUM_ELEMENTS],
    output logic [BIT_LEN-1:0]      lut3_data[NUM_ELEMENTS][LUT_NUM_ELEMENTS],
    output logic [BIT_LEN-1:0]      lut4_data[NUM_ELEMENTS][LUT_NUM_ELEMENTS],
    output logic [BIT_LEN-1:0]      lut5_data[NUM_ELEMENTS][LUT_NUM_ELEMENTS],
/* verilator lint_off UNUSED */
    input                           we,
    input [DIN_LEN-1:0]             din,
    input                           din_valid
/* verilator lint_on UNUSED */
   );

   // 8 bit lookups
   localparam int NUM_LUT_ENTRIES   = 2**(LOOK_UP_WIDTH);
   localparam int LUT_WIDTH         = WORD_LEN * NONREDUNDANT_ELEMENTS;

   localparam int NUM_BRAM          = LUT_NUM_ELEMENTS;

   logic [0:0]            lut4_addr_q[LUT_NUM_ELEMENTS];
   logic [0:0]            lut5_addr_q[LUT_NUM_ELEMENTS];
   logic [LUT_WIDTH-1:0]  lut0_read_data[LUT_NUM_ELEMENTS];
   logic [LUT_WIDTH-1:0]  lut1_read_data[LUT_NUM_ELEMENTS];
   logic [LUT_WIDTH-1:0]  lut2_read_data[LUT_NUM_ELEMENTS];
   logic [LUT_WIDTH-1:0]  lut3_read_data[LUT_NUM_ELEMENTS];
   logic [LUT_WIDTH-1:0]  lut4_read_data[LUT_NUM_ELEMENTS];
   logic [LUT_WIDTH-1:0]  lut5_read_data[LUT_NUM_ELEMENTS];
   logic [LUT_WIDTH-1:0]  lut0_read_data_bram[NUM_BRAM];
   logic [LUT_WIDTH-1:0]  lut1_read_data_bram[NUM_BRAM];
   logic [LUT_WIDTH-1:0]  lut2_read_data_bram[NUM_BRAM];
   logic [LUT_WIDTH-1:0]  lut3_read_data_bram[NUM_BRAM];
   logic [LUT_WIDTH-1:0]  lut4_read_data_bram[NUM_BRAM];
   logic [LUT_WIDTH-1:0]  lut5_read_data_bram[NUM_BRAM];
   logic [BIT_LEN-1:0]    lut0_output[NUM_ELEMENTS][LUT_NUM_ELEMENTS];
   logic [BIT_LEN-1:0]    lut1_output[NUM_ELEMENTS][LUT_NUM_ELEMENTS];
   logic [BIT_LEN-1:0]    lut2_output[NUM_ELEMENTS][LUT_NUM_ELEMENTS];
   logic [BIT_LEN-1:0]    lut3_output[NUM_ELEMENTS][LUT_NUM_ELEMENTS];
   logic [BIT_LEN-1:0]    lut4_output[NUM_ELEMENTS][LUT_NUM_ELEMENTS];
   logic [BIT_LEN-1:0]    lut5_output[NUM_ELEMENTS][LUT_NUM_ELEMENTS];

   // Delay to align with data from memory
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut0_000[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut0_001[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut0_002[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut0_003[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut0_004[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut0_005[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut0_006[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut0_007[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut0_008[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut0_009[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut0_010[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut0_011[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut0_012[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut0_013[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut0_014[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut0_015[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut0_016[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut0_017[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut0_018[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut0_019[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut0_020[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut0_021[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut0_022[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut0_023[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut0_024[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut0_025[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut0_026[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut0_027[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut0_028[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut0_029[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut0_030[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut0_031[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut0_032[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut0_033[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut0_034[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut0_035[NUM_LUT_ENTRIES];

   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut1_000[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut1_001[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut1_002[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut1_003[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut1_004[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut1_005[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut1_006[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut1_007[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut1_008[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut1_009[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut1_010[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut1_011[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut1_012[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut1_013[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut1_014[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut1_015[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut1_016[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut1_017[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut1_018[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut1_019[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut1_020[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut1_021[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut1_022[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut1_023[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut1_024[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut1_025[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut1_026[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut1_027[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut1_028[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut1_029[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut1_030[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut1_031[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut1_032[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut1_033[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut1_034[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut1_035[NUM_LUT_ENTRIES];

   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut2_000[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut2_001[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut2_002[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut2_003[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut2_004[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut2_005[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut2_006[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut2_007[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut2_008[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut2_009[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut2_010[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut2_011[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut2_012[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut2_013[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut2_014[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut2_015[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut2_016[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut2_017[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut2_018[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut2_019[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut2_020[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut2_021[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut2_022[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut2_023[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut2_024[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut2_025[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut2_026[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut2_027[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut2_028[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut2_029[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut2_030[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut2_031[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut2_032[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut2_033[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut2_034[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut2_035[NUM_LUT_ENTRIES];

   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut3_000[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut3_001[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut3_002[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut3_003[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut3_004[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut3_005[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut3_006[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut3_007[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut3_008[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut3_009[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut3_010[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut3_011[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut3_012[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut3_013[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut3_014[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut3_015[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut3_016[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut3_017[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut3_018[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut3_019[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut3_020[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut3_021[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut3_022[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut3_023[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut3_024[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut3_025[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut3_026[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut3_027[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut3_028[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut3_029[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut3_030[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut3_031[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut3_032[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut3_033[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut3_034[NUM_LUT_ENTRIES];
   (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut3_035[NUM_LUT_ENTRIES];

   logic [LUT_WIDTH-1:0] lut4_000[2];
   logic [LUT_WIDTH-1:0] lut4_001[2];
   logic [LUT_WIDTH-1:0] lut4_002[2];
   logic [LUT_WIDTH-1:0] lut4_003[2];
   logic [LUT_WIDTH-1:0] lut4_004[2];
   logic [LUT_WIDTH-1:0] lut4_005[2];
   logic [LUT_WIDTH-1:0] lut4_006[2];
   logic [LUT_WIDTH-1:0] lut4_007[2];
   logic [LUT_WIDTH-1:0] lut4_008[2];
   logic [LUT_WIDTH-1:0] lut4_009[2];
   logic [LUT_WIDTH-1:0] lut4_010[2];
   logic [LUT_WIDTH-1:0] lut4_011[2];
   logic [LUT_WIDTH-1:0] lut4_012[2];
   logic [LUT_WIDTH-1:0] lut4_013[2];
   logic [LUT_WIDTH-1:0] lut4_014[2];
   logic [LUT_WIDTH-1:0] lut4_015[2];
   logic [LUT_WIDTH-1:0] lut4_016[2];
   logic [LUT_WIDTH-1:0] lut4_017[2];
   logic [LUT_WIDTH-1:0] lut4_018[2];
   logic [LUT_WIDTH-1:0] lut4_019[2];
   logic [LUT_WIDTH-1:0] lut4_020[2];
   logic [LUT_WIDTH-1:0] lut4_021[2];
   logic [LUT_WIDTH-1:0] lut4_022[2];
   logic [LUT_WIDTH-1:0] lut4_023[2];
   logic [LUT_WIDTH-1:0] lut4_024[2];
   logic [LUT_WIDTH-1:0] lut4_025[2];
   logic [LUT_WIDTH-1:0] lut4_026[2];
   logic [LUT_WIDTH-1:0] lut4_027[2];
   logic [LUT_WIDTH-1:0] lut4_028[2];
   logic [LUT_WIDTH-1:0] lut4_029[2];
   logic [LUT_WIDTH-1:0] lut4_030[2];
   logic [LUT_WIDTH-1:0] lut4_031[2];
   logic [LUT_WIDTH-1:0] lut4_032[2];
   logic [LUT_WIDTH-1:0] lut4_033[2];
   logic [LUT_WIDTH-1:0] lut4_034[2];
   logic [LUT_WIDTH-1:0] lut4_035[2];

   logic [LUT_WIDTH-1:0] lut5_000[2];
   logic [LUT_WIDTH-1:0] lut5_001[2];
   logic [LUT_WIDTH-1:0] lut5_002[2];
   logic [LUT_WIDTH-1:0] lut5_003[2];
   logic [LUT_WIDTH-1:0] lut5_004[2];
   logic [LUT_WIDTH-1:0] lut5_005[2];
   logic [LUT_WIDTH-1:0] lut5_006[2];
   logic [LUT_WIDTH-1:0] lut5_007[2];
   logic [LUT_WIDTH-1:0] lut5_008[2];
   logic [LUT_WIDTH-1:0] lut5_009[2];
   logic [LUT_WIDTH-1:0] lut5_010[2];
   logic [LUT_WIDTH-1:0] lut5_011[2];
   logic [LUT_WIDTH-1:0] lut5_012[2];
   logic [LUT_WIDTH-1:0] lut5_013[2];
   logic [LUT_WIDTH-1:0] lut5_014[2];
   logic [LUT_WIDTH-1:0] lut5_015[2];
   logic [LUT_WIDTH-1:0] lut5_016[2];
   logic [LUT_WIDTH-1:0] lut5_017[2];
   logic [LUT_WIDTH-1:0] lut5_018[2];
   logic [LUT_WIDTH-1:0] lut5_019[2];
   logic [LUT_WIDTH-1:0] lut5_020[2];
   logic [LUT_WIDTH-1:0] lut5_021[2];
   logic [LUT_WIDTH-1:0] lut5_022[2];
   logic [LUT_WIDTH-1:0] lut5_023[2];
   logic [LUT_WIDTH-1:0] lut5_024[2];
   logic [LUT_WIDTH-1:0] lut5_025[2];
   logic [LUT_WIDTH-1:0] lut5_026[2];
   logic [LUT_WIDTH-1:0] lut5_027[2];
   logic [LUT_WIDTH-1:0] lut5_028[2];
   logic [LUT_WIDTH-1:0] lut5_029[2];
   logic [LUT_WIDTH-1:0] lut5_030[2];
   logic [LUT_WIDTH-1:0] lut5_031[2];
   logic [LUT_WIDTH-1:0] lut5_032[2];
   logic [LUT_WIDTH-1:0] lut5_033[2];
   logic [LUT_WIDTH-1:0] lut5_034[2];
   logic [LUT_WIDTH-1:0] lut5_035[2];

   initial begin
      $readmemh("reduction_lut_54_000.dat", lut0_000);
      $readmemh("reduction_lut_54_001.dat", lut0_001);
      $readmemh("reduction_lut_54_002.dat", lut0_002);
      $readmemh("reduction_lut_54_003.dat", lut0_003);
      $readmemh("reduction_lut_54_004.dat", lut0_004);
      $readmemh("reduction_lut_54_005.dat", lut0_005);
      $readmemh("reduction_lut_54_006.dat", lut0_006);
      $readmemh("reduction_lut_54_007.dat", lut0_007);
      $readmemh("reduction_lut_54_008.dat", lut0_008);
      $readmemh("reduction_lut_54_009.dat", lut0_009);
      $readmemh("reduction_lut_54_010.dat", lut0_010);
      $readmemh("reduction_lut_54_011.dat", lut0_011);
      $readmemh("reduction_lut_54_012.dat", lut0_012);
      $readmemh("reduction_lut_54_013.dat", lut0_013);
      $readmemh("reduction_lut_54_014.dat", lut0_014);
      $readmemh("reduction_lut_54_015.dat", lut0_015);
      $readmemh("reduction_lut_54_016.dat", lut0_016);
      $readmemh("reduction_lut_54_017.dat", lut0_017);
      $readmemh("reduction_lut_54_018.dat", lut0_018);
      $readmemh("reduction_lut_54_019.dat", lut0_019);
      $readmemh("reduction_lut_54_020.dat", lut0_020);
      $readmemh("reduction_lut_54_021.dat", lut0_021);
      $readmemh("reduction_lut_54_022.dat", lut0_022);
      $readmemh("reduction_lut_54_023.dat", lut0_023);
      $readmemh("reduction_lut_54_024.dat", lut0_024);
      $readmemh("reduction_lut_54_025.dat", lut0_025);
      $readmemh("reduction_lut_54_026.dat", lut0_026);
      $readmemh("reduction_lut_54_027.dat", lut0_027);
      $readmemh("reduction_lut_54_028.dat", lut0_028);
      $readmemh("reduction_lut_54_029.dat", lut0_029);
      $readmemh("reduction_lut_54_030.dat", lut0_030);
      $readmemh("reduction_lut_54_031.dat", lut0_031);
      $readmemh("reduction_lut_54_032.dat", lut0_032);
      $readmemh("reduction_lut_54_033.dat", lut0_033);
      $readmemh("reduction_lut_54_034.dat", lut0_034);
      $readmemh("reduction_lut_54_035.dat", lut0_035);

      $readmemh("reduction_lut_54_000.dat", lut1_000);
      $readmemh("reduction_lut_54_001.dat", lut1_001);
      $readmemh("reduction_lut_54_002.dat", lut1_002);
      $readmemh("reduction_lut_54_003.dat", lut1_003);
      $readmemh("reduction_lut_54_004.dat", lut1_004);
      $readmemh("reduction_lut_54_005.dat", lut1_005);
      $readmemh("reduction_lut_54_006.dat", lut1_006);
      $readmemh("reduction_lut_54_007.dat", lut1_007);
      $readmemh("reduction_lut_54_008.dat", lut1_008);
      $readmemh("reduction_lut_54_009.dat", lut1_009);
      $readmemh("reduction_lut_54_010.dat", lut1_010);
      $readmemh("reduction_lut_54_011.dat", lut1_011);
      $readmemh("reduction_lut_54_012.dat", lut1_012);
      $readmemh("reduction_lut_54_013.dat", lut1_013);
      $readmemh("reduction_lut_54_014.dat", lut1_014);
      $readmemh("reduction_lut_54_015.dat", lut1_015);
      $readmemh("reduction_lut_54_016.dat", lut1_016);
      $readmemh("reduction_lut_54_017.dat", lut1_017);
      $readmemh("reduction_lut_54_018.dat", lut1_018);
      $readmemh("reduction_lut_54_019.dat", lut1_019);
      $readmemh("reduction_lut_54_020.dat", lut1_020);
      $readmemh("reduction_lut_54_021.dat", lut1_021);
      $readmemh("reduction_lut_54_022.dat", lut1_022);
      $readmemh("reduction_lut_54_023.dat", lut1_023);
      $readmemh("reduction_lut_54_024.dat", lut1_024);
      $readmemh("reduction_lut_54_025.dat", lut1_025);
      $readmemh("reduction_lut_54_026.dat", lut1_026);
      $readmemh("reduction_lut_54_027.dat", lut1_027);
      $readmemh("reduction_lut_54_028.dat", lut1_028);
      $readmemh("reduction_lut_54_029.dat", lut1_029);
      $readmemh("reduction_lut_54_030.dat", lut1_030);
      $readmemh("reduction_lut_54_031.dat", lut1_031);
      $readmemh("reduction_lut_54_032.dat", lut1_032);
      $readmemh("reduction_lut_54_033.dat", lut1_033);
      $readmemh("reduction_lut_54_034.dat", lut1_034);
      $readmemh("reduction_lut_54_035.dat", lut1_035);

      $readmemh("reduction_lut_76_000.dat", lut2_000);
      $readmemh("reduction_lut_76_001.dat", lut2_001);
      $readmemh("reduction_lut_76_002.dat", lut2_002);
      $readmemh("reduction_lut_76_003.dat", lut2_003);
      $readmemh("reduction_lut_76_004.dat", lut2_004);
      $readmemh("reduction_lut_76_005.dat", lut2_005);
      $readmemh("reduction_lut_76_006.dat", lut2_006);
      $readmemh("reduction_lut_76_007.dat", lut2_007);
      $readmemh("reduction_lut_76_008.dat", lut2_008);
      $readmemh("reduction_lut_76_009.dat", lut2_009);
      $readmemh("reduction_lut_76_010.dat", lut2_010);
      $readmemh("reduction_lut_76_011.dat", lut2_011);
      $readmemh("reduction_lut_76_012.dat", lut2_012);
      $readmemh("reduction_lut_76_013.dat", lut2_013);
      $readmemh("reduction_lut_76_014.dat", lut2_014);
      $readmemh("reduction_lut_76_015.dat", lut2_015);
      $readmemh("reduction_lut_76_016.dat", lut2_016);
      $readmemh("reduction_lut_76_017.dat", lut2_017);
      $readmemh("reduction_lut_76_018.dat", lut2_018);
      $readmemh("reduction_lut_76_019.dat", lut2_019);
      $readmemh("reduction_lut_76_020.dat", lut2_020);
      $readmemh("reduction_lut_76_021.dat", lut2_021);
      $readmemh("reduction_lut_76_022.dat", lut2_022);
      $readmemh("reduction_lut_76_023.dat", lut2_023);
      $readmemh("reduction_lut_76_024.dat", lut2_024);
      $readmemh("reduction_lut_76_025.dat", lut2_025);
      $readmemh("reduction_lut_76_026.dat", lut2_026);
      $readmemh("reduction_lut_76_027.dat", lut2_027);
      $readmemh("reduction_lut_76_028.dat", lut2_028);
      $readmemh("reduction_lut_76_029.dat", lut2_029);
      $readmemh("reduction_lut_76_030.dat", lut2_030);
      $readmemh("reduction_lut_76_031.dat", lut2_031);
      $readmemh("reduction_lut_76_032.dat", lut2_032);
      $readmemh("reduction_lut_76_033.dat", lut2_033);
      $readmemh("reduction_lut_76_034.dat", lut2_034);
      $readmemh("reduction_lut_76_035.dat", lut2_035);

      $readmemh("reduction_lut_76_000.dat", lut3_000);
      $readmemh("reduction_lut_76_001.dat", lut3_001);
      $readmemh("reduction_lut_76_002.dat", lut3_002);
      $readmemh("reduction_lut_76_003.dat", lut3_003);
      $readmemh("reduction_lut_76_004.dat", lut3_004);
      $readmemh("reduction_lut_76_005.dat", lut3_005);
      $readmemh("reduction_lut_76_006.dat", lut3_006);
      $readmemh("reduction_lut_76_007.dat", lut3_007);
      $readmemh("reduction_lut_76_008.dat", lut3_008);
      $readmemh("reduction_lut_76_009.dat", lut3_009);
      $readmemh("reduction_lut_76_010.dat", lut3_010);
      $readmemh("reduction_lut_76_011.dat", lut3_011);
      $readmemh("reduction_lut_76_012.dat", lut3_012);
      $readmemh("reduction_lut_76_013.dat", lut3_013);
      $readmemh("reduction_lut_76_014.dat", lut3_014);
      $readmemh("reduction_lut_76_015.dat", lut3_015);
      $readmemh("reduction_lut_76_016.dat", lut3_016);
      $readmemh("reduction_lut_76_017.dat", lut3_017);
      $readmemh("reduction_lut_76_018.dat", lut3_018);
      $readmemh("reduction_lut_76_019.dat", lut3_019);
      $readmemh("reduction_lut_76_020.dat", lut3_020);
      $readmemh("reduction_lut_76_021.dat", lut3_021);
      $readmemh("reduction_lut_76_022.dat", lut3_022);
      $readmemh("reduction_lut_76_023.dat", lut3_023);
      $readmemh("reduction_lut_76_024.dat", lut3_024);
      $readmemh("reduction_lut_76_025.dat", lut3_025);
      $readmemh("reduction_lut_76_026.dat", lut3_026);
      $readmemh("reduction_lut_76_027.dat", lut3_027);
      $readmemh("reduction_lut_76_028.dat", lut3_028);
      $readmemh("reduction_lut_76_029.dat", lut3_029);
      $readmemh("reduction_lut_76_030.dat", lut3_030);
      $readmemh("reduction_lut_76_031.dat", lut3_031);
      $readmemh("reduction_lut_76_032.dat", lut3_032);
      $readmemh("reduction_lut_76_033.dat", lut3_033);
      $readmemh("reduction_lut_76_034.dat", lut3_034);
      $readmemh("reduction_lut_76_035.dat", lut3_035);

      $readmemh("reduction_lut_54_000.dat", lut4_000);
      $readmemh("reduction_lut_54_001.dat", lut4_001);
      $readmemh("reduction_lut_54_002.dat", lut4_002);
      $readmemh("reduction_lut_54_003.dat", lut4_003);
      $readmemh("reduction_lut_54_004.dat", lut4_004);
      $readmemh("reduction_lut_54_005.dat", lut4_005);
      $readmemh("reduction_lut_54_006.dat", lut4_006);
      $readmemh("reduction_lut_54_007.dat", lut4_007);
      $readmemh("reduction_lut_54_008.dat", lut4_008);
      $readmemh("reduction_lut_54_009.dat", lut4_009);
      $readmemh("reduction_lut_54_010.dat", lut4_010);
      $readmemh("reduction_lut_54_011.dat", lut4_011);
      $readmemh("reduction_lut_54_012.dat", lut4_012);
      $readmemh("reduction_lut_54_013.dat", lut4_013);
      $readmemh("reduction_lut_54_014.dat", lut4_014);
      $readmemh("reduction_lut_54_015.dat", lut4_015);
      $readmemh("reduction_lut_54_016.dat", lut4_016);
      $readmemh("reduction_lut_54_017.dat", lut4_017);
      $readmemh("reduction_lut_54_018.dat", lut4_018);
      $readmemh("reduction_lut_54_019.dat", lut4_019);
      $readmemh("reduction_lut_54_020.dat", lut4_020);
      $readmemh("reduction_lut_54_021.dat", lut4_021);
      $readmemh("reduction_lut_54_022.dat", lut4_022);
      $readmemh("reduction_lut_54_023.dat", lut4_023);
      $readmemh("reduction_lut_54_024.dat", lut4_024);
      $readmemh("reduction_lut_54_025.dat", lut4_025);
      $readmemh("reduction_lut_54_026.dat", lut4_026);
      $readmemh("reduction_lut_54_027.dat", lut4_027);
      $readmemh("reduction_lut_54_028.dat", lut4_028);
      $readmemh("reduction_lut_54_029.dat", lut4_029);
      $readmemh("reduction_lut_54_030.dat", lut4_030);
      $readmemh("reduction_lut_54_031.dat", lut4_031);
      $readmemh("reduction_lut_54_032.dat", lut4_032);
      $readmemh("reduction_lut_54_033.dat", lut4_033);
      $readmemh("reduction_lut_54_034.dat", lut4_034);
      $readmemh("reduction_lut_54_035.dat", lut4_035);

      $readmemh("reduction_lut_76_000.dat", lut5_000);
      $readmemh("reduction_lut_76_001.dat", lut5_001);
      $readmemh("reduction_lut_76_002.dat", lut5_002);
      $readmemh("reduction_lut_76_003.dat", lut5_003);
      $readmemh("reduction_lut_76_004.dat", lut5_004);
      $readmemh("reduction_lut_76_005.dat", lut5_005);
      $readmemh("reduction_lut_76_006.dat", lut5_006);
      $readmemh("reduction_lut_76_007.dat", lut5_007);
      $readmemh("reduction_lut_76_008.dat", lut5_008);
      $readmemh("reduction_lut_76_009.dat", lut5_009);
      $readmemh("reduction_lut_76_010.dat", lut5_010);
      $readmemh("reduction_lut_76_011.dat", lut5_011);
      $readmemh("reduction_lut_76_012.dat", lut5_012);
      $readmemh("reduction_lut_76_013.dat", lut5_013);
      $readmemh("reduction_lut_76_014.dat", lut5_014);
      $readmemh("reduction_lut_76_015.dat", lut5_015);
      $readmemh("reduction_lut_76_016.dat", lut5_016);
      $readmemh("reduction_lut_76_017.dat", lut5_017);
      $readmemh("reduction_lut_76_018.dat", lut5_018);
      $readmemh("reduction_lut_76_019.dat", lut5_019);
      $readmemh("reduction_lut_76_020.dat", lut5_020);
      $readmemh("reduction_lut_76_021.dat", lut5_021);
      $readmemh("reduction_lut_76_022.dat", lut5_022);
      $readmemh("reduction_lut_76_023.dat", lut5_023);
      $readmemh("reduction_lut_76_024.dat", lut5_024);
      $readmemh("reduction_lut_76_025.dat", lut5_025);
      $readmemh("reduction_lut_76_026.dat", lut5_026);
      $readmemh("reduction_lut_76_027.dat", lut5_027);
      $readmemh("reduction_lut_76_028.dat", lut5_028);
      $readmemh("reduction_lut_76_029.dat", lut5_029);
      $readmemh("reduction_lut_76_030.dat", lut5_030);
      $readmemh("reduction_lut_76_031.dat", lut5_031);
      $readmemh("reduction_lut_76_032.dat", lut5_032);
      $readmemh("reduction_lut_76_033.dat", lut5_033);
      $readmemh("reduction_lut_76_034.dat", lut5_034);
      $readmemh("reduction_lut_76_035.dat", lut5_035);
   end

   always_ff @(posedge clk) begin
      lut0_read_data_bram[0]  <= lut0_000[lut0_addr[0]];
      lut0_read_data_bram[1]  <= lut0_001[lut0_addr[1]];
      lut0_read_data_bram[2]  <= lut0_002[lut0_addr[2]];
      lut0_read_data_bram[3]  <= lut0_003[lut0_addr[3]];
      lut0_read_data_bram[4]  <= lut0_004[lut0_addr[4]];
      lut0_read_data_bram[5]  <= lut0_005[lut0_addr[5]];
      lut0_read_data_bram[6]  <= lut0_006[lut0_addr[6]];
      lut0_read_data_bram[7]  <= lut0_007[lut0_addr[7]];
      lut0_read_data_bram[8]  <= lut0_008[lut0_addr[8]];
      lut0_read_data_bram[9]  <= lut0_009[lut0_addr[9]];
      lut0_read_data_bram[10] <= lut0_010[lut0_addr[10]];
      lut0_read_data_bram[11] <= lut0_011[lut0_addr[11]];
      lut0_read_data_bram[12] <= lut0_012[lut0_addr[12]];
      lut0_read_data_bram[13] <= lut0_013[lut0_addr[13]];
      lut0_read_data_bram[14] <= lut0_014[lut0_addr[14]];
      lut0_read_data_bram[15] <= lut0_015[lut0_addr[15]];
      lut0_read_data_bram[16] <= lut0_016[lut0_addr[16]];
      lut0_read_data_bram[17] <= lut0_017[lut0_addr[17]];
      lut0_read_data_bram[18] <= lut0_018[lut0_addr[18]];
      lut0_read_data_bram[19] <= lut0_019[lut0_addr[19]];
      lut0_read_data_bram[20] <= lut0_020[lut0_addr[20]];
      lut0_read_data_bram[21] <= lut0_021[lut0_addr[21]];
      lut0_read_data_bram[22] <= lut0_022[lut0_addr[22]];
      lut0_read_data_bram[23] <= lut0_023[lut0_addr[23]];
      lut0_read_data_bram[24] <= lut0_024[lut0_addr[24]];
      lut0_read_data_bram[25] <= lut0_025[lut0_addr[25]];
      lut0_read_data_bram[26] <= lut0_026[lut0_addr[26]];
      lut0_read_data_bram[27] <= lut0_027[lut0_addr[27]];
      lut0_read_data_bram[28] <= lut0_028[lut0_addr[28]];
      lut0_read_data_bram[29] <= lut0_029[lut0_addr[29]];
      lut0_read_data_bram[30] <= lut0_030[lut0_addr[30]];
      lut0_read_data_bram[31] <= lut0_031[lut0_addr[31]];
      lut0_read_data_bram[32] <= lut0_032[lut0_addr[32]];
      lut0_read_data_bram[33] <= lut0_033[lut0_addr[33]];
      lut0_read_data_bram[34] <= lut0_034[lut0_addr[34]];
      lut0_read_data_bram[35] <= lut0_035[lut0_addr[35]];

      lut1_read_data_bram[0]  <= lut1_000[lut1_addr[0]];
      lut1_read_data_bram[1]  <= lut1_001[lut1_addr[1]];
      lut1_read_data_bram[2]  <= lut1_002[lut1_addr[2]];
      lut1_read_data_bram[3]  <= lut1_003[lut1_addr[3]];
      lut1_read_data_bram[4]  <= lut1_004[lut1_addr[4]];
      lut1_read_data_bram[5]  <= lut1_005[lut1_addr[5]];
      lut1_read_data_bram[6]  <= lut1_006[lut1_addr[6]];
      lut1_read_data_bram[7]  <= lut1_007[lut1_addr[7]];
      lut1_read_data_bram[8]  <= lut1_008[lut1_addr[8]];
      lut1_read_data_bram[9]  <= lut1_009[lut1_addr[9]];
      lut1_read_data_bram[10] <= lut1_010[lut1_addr[10]];
      lut1_read_data_bram[11] <= lut1_011[lut1_addr[11]];
      lut1_read_data_bram[12] <= lut1_012[lut1_addr[12]];
      lut1_read_data_bram[13] <= lut1_013[lut1_addr[13]];
      lut1_read_data_bram[14] <= lut1_014[lut1_addr[14]];
      lut1_read_data_bram[15] <= lut1_015[lut1_addr[15]];
      lut1_read_data_bram[16] <= lut1_016[lut1_addr[16]];
      lut1_read_data_bram[17] <= lut1_017[lut1_addr[17]];
      lut1_read_data_bram[18] <= lut1_018[lut1_addr[18]];
      lut1_read_data_bram[19] <= lut1_019[lut1_addr[19]];
      lut1_read_data_bram[20] <= lut1_020[lut1_addr[20]];
      lut1_read_data_bram[21] <= lut1_021[lut1_addr[21]];
      lut1_read_data_bram[22] <= lut1_022[lut1_addr[22]];
      lut1_read_data_bram[23] <= lut1_023[lut1_addr[23]];
      lut1_read_data_bram[24] <= lut1_024[lut1_addr[24]];
      lut1_read_data_bram[25] <= lut1_025[lut1_addr[25]];
      lut1_read_data_bram[26] <= lut1_026[lut1_addr[26]];
      lut1_read_data_bram[27] <= lut1_027[lut1_addr[27]];
      lut1_read_data_bram[28] <= lut1_028[lut1_addr[28]];
      lut1_read_data_bram[29] <= lut1_029[lut1_addr[29]];
      lut1_read_data_bram[30] <= lut1_030[lut1_addr[30]];
      lut1_read_data_bram[31] <= lut1_031[lut1_addr[31]];
      lut1_read_data_bram[32] <= lut1_032[lut1_addr[32]];
      lut1_read_data_bram[33] <= lut1_033[lut1_addr[33]];
      lut1_read_data_bram[34] <= lut1_034[lut1_addr[34]];
      lut1_read_data_bram[35] <= lut1_035[lut1_addr[35]];

      lut2_read_data_bram[0]  <= lut2_000[lut2_addr[0]];
      lut2_read_data_bram[1]  <= lut2_001[lut2_addr[1]];
      lut2_read_data_bram[2]  <= lut2_002[lut2_addr[2]];
      lut2_read_data_bram[3]  <= lut2_003[lut2_addr[3]];
      lut2_read_data_bram[4]  <= lut2_004[lut2_addr[4]];
      lut2_read_data_bram[5]  <= lut2_005[lut2_addr[5]];
      lut2_read_data_bram[6]  <= lut2_006[lut2_addr[6]];
      lut2_read_data_bram[7]  <= lut2_007[lut2_addr[7]];
      lut2_read_data_bram[8]  <= lut2_008[lut2_addr[8]];
      lut2_read_data_bram[9]  <= lut2_009[lut2_addr[9]];
      lut2_read_data_bram[10] <= lut2_010[lut2_addr[10]];
      lut2_read_data_bram[11] <= lut2_011[lut2_addr[11]];
      lut2_read_data_bram[12] <= lut2_012[lut2_addr[12]];
      lut2_read_data_bram[13] <= lut2_013[lut2_addr[13]];
      lut2_read_data_bram[14] <= lut2_014[lut2_addr[14]];
      lut2_read_data_bram[15] <= lut2_015[lut2_addr[15]];
      lut2_read_data_bram[16] <= lut2_016[lut2_addr[16]];
      lut2_read_data_bram[17] <= lut2_017[lut2_addr[17]];
      lut2_read_data_bram[18] <= lut2_018[lut2_addr[18]];
      lut2_read_data_bram[19] <= lut2_019[lut2_addr[19]];
      lut2_read_data_bram[20] <= lut2_020[lut2_addr[20]];
      lut2_read_data_bram[21] <= lut2_021[lut2_addr[21]];
      lut2_read_data_bram[22] <= lut2_022[lut2_addr[22]];
      lut2_read_data_bram[23] <= lut2_023[lut2_addr[23]];
      lut2_read_data_bram[24] <= lut2_024[lut2_addr[24]];
      lut2_read_data_bram[25] <= lut2_025[lut2_addr[25]];
      lut2_read_data_bram[26] <= lut2_026[lut2_addr[26]];
      lut2_read_data_bram[27] <= lut2_027[lut2_addr[27]];
      lut2_read_data_bram[28] <= lut2_028[lut2_addr[28]];
      lut2_read_data_bram[29] <= lut2_029[lut2_addr[29]];
      lut2_read_data_bram[30] <= lut2_030[lut2_addr[30]];
      lut2_read_data_bram[31] <= lut2_031[lut2_addr[31]];
      lut2_read_data_bram[32] <= lut2_032[lut2_addr[32]];
      lut2_read_data_bram[33] <= lut2_033[lut2_addr[33]];
      lut2_read_data_bram[34] <= lut2_034[lut2_addr[34]];
      lut2_read_data_bram[35] <= lut2_035[lut2_addr[35]];

      lut3_read_data_bram[0]  <= lut3_000[lut0_addr[0]];
      lut3_read_data_bram[1]  <= lut3_001[lut0_addr[1]];
      lut3_read_data_bram[2]  <= lut3_002[lut0_addr[2]];
      lut3_read_data_bram[3]  <= lut3_003[lut0_addr[3]];
      lut3_read_data_bram[4]  <= lut3_004[lut0_addr[4]];
      lut3_read_data_bram[5]  <= lut3_005[lut0_addr[5]];
      lut3_read_data_bram[6]  <= lut3_006[lut0_addr[6]];
      lut3_read_data_bram[7]  <= lut3_007[lut0_addr[7]];
      lut3_read_data_bram[8]  <= lut3_008[lut0_addr[8]];
      lut3_read_data_bram[9]  <= lut3_009[lut0_addr[9]];
      lut3_read_data_bram[10] <= lut3_010[lut0_addr[10]];
      lut3_read_data_bram[11] <= lut3_011[lut0_addr[11]];
      lut3_read_data_bram[12] <= lut3_012[lut0_addr[12]];
      lut3_read_data_bram[13] <= lut3_013[lut0_addr[13]];
      lut3_read_data_bram[14] <= lut3_014[lut0_addr[14]];
      lut3_read_data_bram[15] <= lut3_015[lut0_addr[15]];
      lut3_read_data_bram[16] <= lut3_016[lut0_addr[16]];
      lut3_read_data_bram[17] <= lut3_017[lut0_addr[17]];
      lut3_read_data_bram[18] <= lut3_018[lut0_addr[18]];
      lut3_read_data_bram[19] <= lut3_019[lut0_addr[19]];
      lut3_read_data_bram[20] <= lut3_020[lut0_addr[20]];
      lut3_read_data_bram[21] <= lut3_021[lut0_addr[21]];
      lut3_read_data_bram[22] <= lut3_022[lut0_addr[22]];
      lut3_read_data_bram[23] <= lut3_023[lut0_addr[23]];
      lut3_read_data_bram[24] <= lut3_024[lut0_addr[24]];
      lut3_read_data_bram[25] <= lut3_025[lut0_addr[25]];
      lut3_read_data_bram[26] <= lut3_026[lut0_addr[26]];
      lut3_read_data_bram[27] <= lut3_027[lut0_addr[27]];
      lut3_read_data_bram[28] <= lut3_028[lut0_addr[28]];
      lut3_read_data_bram[29] <= lut3_029[lut0_addr[29]];
      lut3_read_data_bram[30] <= lut3_030[lut0_addr[30]];
      lut3_read_data_bram[31] <= lut3_031[lut0_addr[31]];
      lut3_read_data_bram[32] <= lut3_032[lut0_addr[32]];
      lut3_read_data_bram[33] <= lut3_033[lut0_addr[33]];
      lut3_read_data_bram[34] <= lut3_034[lut0_addr[34]];
      lut3_read_data_bram[35] <= lut3_035[lut0_addr[35]];
   end


  always_ff @(posedge clk) begin
      lut4_addr_q <= lut4_addr;
      lut5_addr_q <= lut5_addr;
  end  
  
  always_comb begin
      lut4_read_data_bram[0]  = lut4_000[lut4_addr_q[0 ]];
      lut4_read_data_bram[1]  = lut4_001[lut4_addr_q[1 ]];
      lut4_read_data_bram[2]  = lut4_002[lut4_addr_q[2 ]];
      lut4_read_data_bram[3]  = lut4_003[lut4_addr_q[3 ]];
      lut4_read_data_bram[4]  = lut4_004[lut4_addr_q[4 ]];
      lut4_read_data_bram[5]  = lut4_005[lut4_addr_q[5 ]];
      lut4_read_data_bram[6]  = lut4_006[lut4_addr_q[6 ]];
      lut4_read_data_bram[7]  = lut4_007[lut4_addr_q[7 ]];
      lut4_read_data_bram[8]  = lut4_008[lut4_addr_q[8 ]];
      lut4_read_data_bram[9]  = lut4_009[lut4_addr_q[9 ]];
      lut4_read_data_bram[10] = lut4_010[lut4_addr_q[10]];
      lut4_read_data_bram[11] = lut4_011[lut4_addr_q[11]];
      lut4_read_data_bram[12] = lut4_012[lut4_addr_q[12]];
      lut4_read_data_bram[13] = lut4_013[lut4_addr_q[13]];
      lut4_read_data_bram[14] = lut4_014[lut4_addr_q[14]];
      lut4_read_data_bram[15] = lut4_015[lut4_addr_q[15]];
      lut4_read_data_bram[16] = lut4_016[lut4_addr_q[16]];
      lut4_read_data_bram[17] = lut4_017[lut4_addr_q[17]];
      lut4_read_data_bram[18] = lut4_018[lut4_addr_q[18]];
      lut4_read_data_bram[19] = lut4_019[lut4_addr_q[19]];
      lut4_read_data_bram[20] = lut4_020[lut4_addr_q[20]];
      lut4_read_data_bram[21] = lut4_021[lut4_addr_q[21]];
      lut4_read_data_bram[22] = lut4_022[lut4_addr_q[22]];
      lut4_read_data_bram[23] = lut4_023[lut4_addr_q[23]];
      lut4_read_data_bram[24] = lut4_024[lut4_addr_q[24]];
      lut4_read_data_bram[25] = lut4_025[lut4_addr_q[25]];
      lut4_read_data_bram[26] = lut4_026[lut4_addr_q[26]];
      lut4_read_data_bram[27] = lut4_027[lut4_addr_q[27]];
      lut4_read_data_bram[28] = lut4_028[lut4_addr_q[28]];
      lut4_read_data_bram[29] = lut4_029[lut4_addr_q[29]];
      lut4_read_data_bram[30] = lut4_030[lut4_addr_q[30]];
      lut4_read_data_bram[31] = lut4_031[lut4_addr_q[31]];
      lut4_read_data_bram[32] = lut4_032[lut4_addr_q[32]];
      lut4_read_data_bram[33] = lut4_033[lut4_addr_q[33]];
      lut4_read_data_bram[34] = lut4_034[lut4_addr_q[34]];
      lut4_read_data_bram[35] = lut4_035[lut4_addr_q[35]];
    
      lut5_read_data_bram[0]  = lut5_000[lut5_addr_q[0 ]];
      lut5_read_data_bram[1]  = lut5_001[lut5_addr_q[1 ]];
      lut5_read_data_bram[2]  = lut5_002[lut5_addr_q[2 ]];
      lut5_read_data_bram[3]  = lut5_003[lut5_addr_q[3 ]];
      lut5_read_data_bram[4]  = lut5_004[lut5_addr_q[4 ]];
      lut5_read_data_bram[5]  = lut5_005[lut5_addr_q[5 ]];
      lut5_read_data_bram[6]  = lut5_006[lut5_addr_q[6 ]];
      lut5_read_data_bram[7]  = lut5_007[lut5_addr_q[7 ]];
      lut5_read_data_bram[8]  = lut5_008[lut5_addr_q[8 ]];
      lut5_read_data_bram[9]  = lut5_009[lut5_addr_q[9 ]];
      lut5_read_data_bram[10] = lut5_010[lut5_addr_q[10]];
      lut5_read_data_bram[11] = lut5_011[lut5_addr_q[11]];
      lut5_read_data_bram[12] = lut5_012[lut5_addr_q[12]];
      lut5_read_data_bram[13] = lut5_013[lut5_addr_q[13]];
      lut5_read_data_bram[14] = lut5_014[lut5_addr_q[14]];
      lut5_read_data_bram[15] = lut5_015[lut5_addr_q[15]];
      lut5_read_data_bram[16] = lut5_016[lut5_addr_q[16]];
      lut5_read_data_bram[17] = lut5_017[lut5_addr_q[17]];
      lut5_read_data_bram[18] = lut5_018[lut5_addr_q[18]];
      lut5_read_data_bram[19] = lut5_019[lut5_addr_q[19]];
      lut5_read_data_bram[20] = lut5_020[lut5_addr_q[20]];
      lut5_read_data_bram[21] = lut5_021[lut5_addr_q[21]];
      lut5_read_data_bram[22] = lut5_022[lut5_addr_q[22]];
      lut5_read_data_bram[23] = lut5_023[lut5_addr_q[23]];
      lut5_read_data_bram[24] = lut5_024[lut5_addr_q[24]];
      lut5_read_data_bram[25] = lut5_025[lut5_addr_q[25]];
      lut5_read_data_bram[26] = lut5_026[lut5_addr_q[26]];
      lut5_read_data_bram[27] = lut5_027[lut5_addr_q[27]];
      lut5_read_data_bram[28] = lut5_028[lut5_addr_q[28]];
      lut5_read_data_bram[29] = lut5_029[lut5_addr_q[29]];
      lut5_read_data_bram[30] = lut5_030[lut5_addr_q[30]];
      lut5_read_data_bram[31] = lut5_031[lut5_addr_q[31]];
      lut5_read_data_bram[32] = lut5_032[lut5_addr_q[32]];
      lut5_read_data_bram[33] = lut5_033[lut5_addr_q[33]];
      lut5_read_data_bram[34] = lut5_034[lut5_addr_q[34]];
      lut5_read_data_bram[35] = lut5_035[lut5_addr_q[35]];
   end

   // Read data out of the memories
   always_comb begin
      for (int k=0; k<NUM_BRAM; k=k+1) begin
         lut0_read_data[k] = lut0_read_data_bram[k]; // V54 lsb
         lut1_read_data[k] = lut1_read_data_bram[k]; // V54 msb
         lut2_read_data[k] = lut2_read_data_bram[k]; // V76 lsb
         lut3_read_data[k] = lut3_read_data_bram[k]; // v76 msb
         lut4_read_data[k] = lut4_read_data_bram[k]; // v54 ovf
         lut5_read_data[k] = lut5_read_data_bram[k]; // v76 ovf
      end      
   end

   always_comb begin
      // default all outputs 
      for (int k=0; k<LUT_NUM_ELEMENTS; k=k+1) begin
         for (int l=0; l<NUM_ELEMENTS; l=l+1) begin
            lut0_output[l][k] = '0;
            lut1_output[l][k] = '0;
            lut2_output[l][k] = '0;
            lut3_output[l][k] = '0;
            lut4_output[l][k] = '0;
            lut5_output[l][k] = '0;
         end
      end
      for (int k=0; k<LUT_NUM_ELEMENTS; k=k+1) begin
         for (int l=0; l<NONREDUNDANT_ELEMENTS+1; l=l+1) begin
            if (l == 0) begin
               lut1_output[l][k][LOOK_UP_WIDTH-1:0] = '0;
               lut3_output[l][k][LOOK_UP_WIDTH-1:0] = '0;
            end else begin
               lut1_output[l][k][LOOK_UP_WIDTH-1:0] = lut1_read_data[k][((l-1)*WORD_LEN)+LOOK_UP_WIDTH+:LOOK_UP_WIDTH];
               lut3_output[l][k][LOOK_UP_WIDTH-1:0] = lut3_read_data[k][((l-1)*WORD_LEN)+LOOK_UP_WIDTH+:LOOK_UP_WIDTH];
            end
            
            if (l == 0) begin
               lut4_output[l][k] = '0;
               lut5_output[l][k] = '0;
            end else begin
               lut4_output[l][k] = {{(BIT_LEN-WORD_LEN){1'b0}}, lut4_read_data[k][((l-1)*WORD_LEN)+:WORD_LEN]};
               lut5_output[l][k] = {{(BIT_LEN-WORD_LEN){1'b0}}, lut5_read_data[k][((l-1)*WORD_LEN)+:WORD_LEN]};
            end
            
            if (l < NONREDUNDANT_ELEMENTS) begin
               lut0_output[l][k] = {{(BIT_LEN-WORD_LEN){1'b0}}, lut0_read_data[k][(l*WORD_LEN)+:WORD_LEN]};
               lut2_output[l][k] = {{(BIT_LEN-WORD_LEN){1'b0}}, lut2_read_data[k][(l*WORD_LEN)+:WORD_LEN]};
            end
         end
      end
   end

   // Need above loops in combo block for Verilator to process
   always_comb begin
      lut0_data  = lut0_output;
      lut1_data  = lut1_output;
      lut2_data  = lut2_output;
      lut3_data  = lut3_output;
      lut4_data  = lut4_output;
      lut5_data  = lut5_output;
   end
endmodule

