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


module modular_square_8_cycles
   #(
     parameter int REDUNDANT_ELEMENTS    = 2,
     parameter int NONREDUNDANT_ELEMENTS = 64,
     parameter int NUM_SEGMENTS          = 1,
     parameter int BIT_LEN               = 17,
     parameter int WORD_LEN              = 16,

     parameter int NUM_ELEMENTS          = ( REDUNDANT_ELEMENTS + NONREDUNDANT_ELEMENTS ) // 66 words
    )
   (
    input logic                   clk,
    input logic                   reset,
    input logic                   start,
    input logic [BIT_LEN-1:0]     sq_in[NUM_ELEMENTS],
    output logic [BIT_LEN-1:0]    sq_out[NUM_ELEMENTS],
    output logic                  valid
   );

   localparam int SEGMENT_ELEMENTS    = ( int'(NONREDUNDANT_ELEMENTS / NUM_SEGMENTS) ); // 64 elements of 17b for 1024 bits
   localparam int MUL_NUM_ELEMENTS    = ( REDUNDANT_ELEMENTS + SEGMENT_ELEMENTS );      // 66 elements of 17b to keep 1024 safely

   localparam int EXTRA_ELEMENTS      = 2;
   localparam int NUM_MULTIPLIERS     = 1;
   localparam int EXTRA_MUL_TREE_BITS = 8;  // 7 for CSA of 66 and 1 for 2x AB terms
   localparam int MUL_BIT_LEN         = ( ((BIT_LEN*2) - WORD_LEN) + EXTRA_MUL_TREE_BITS ); // 26b
   localparam int GRID_BIT_LEN        =  MUL_BIT_LEN; // 26b
   localparam int GRID_SIZE           = ( MUL_NUM_ELEMENTS*2 ); // 132 elements in a 2K word
   localparam int LOOK_UP_WIDTH       = 6;

   localparam int ACC_ELEMENTS        = 36;  // 36 luts 
   localparam int ACC_EXTRA_ELEMENTS  = 1; // Addin the lower bits of the product
   localparam int ACC_EXTRA_BIT_LEN   = 8; // WAS: $clog2(ACC_ELEMENTS+ACC_EXTRA_ELEMENTS);
   localparam int ACC_BIT_LEN         = ( BIT_LEN + ACC_EXTRA_BIT_LEN ); // 25b

   localparam int PULSE_ENERGY        = 'h70000;  // energy for 1 modsq stage (each 0.5), (guess 1uJ)
   localparam int MAX_POWER           = 'h20000;   // Max Power, about 64 Watts, must result in 3.5 cycles/pulse
   localparam int POWER_RAMP          = 'h1; //'h100;     // Normal is 1, use larger for sims
      
   localparam int IDLE                = 0,
                  PRECYC_0            = 1,
                  PRECYC_1            = 2,
                  PRECYC_2            = 3,
                  PRECYC_3            = 4,
                  PRECYC_4            = 5,
                  PRECYC_5            = 6,
                  PRECYC_6            = 7,
                  CYCLE_0             = 8,
                  CYCLE_1             = 9,
                  CYCLE_2             = 10,
                  CYCLE_3             = 11,
                  CYCLE_4             = 12,
                  CYCLE_4B            = 13,
                  CYCLE_5             = 14,
                  CYCLE_6             = 15,
                  NUM_CYCLES          = 16;

   // Flop incoming data from external source
   logic [BIT_LEN-1:0]       sq_in_d1[NUM_ELEMENTS];  // 66 x 17b
   logic                     start_d1;

   // Input to square (start of phase 1)
   logic [BIT_LEN-1:0]       curr_sq_in[NUM_ELEMENTS]; // 66 x 17b

   // Cycle number state machine
   logic [NUM_CYCLES-1:0]    next_cycle; // 4 cycles
   logic [NUM_CYCLES-1:0]    curr_cycle; // 4 cycles
   logic [20:0]              power_count;  // power setpoint
   logic [20:0]              energy_error; // accumulated energy error
   logic                     power_ok; // flag to burn power

   // Multiplier selects in/out and values
   logic [MUL_BIT_LEN-1:0]   mul_c[ GRID_SIZE ]; // 132 x 25b
   logic [MUL_BIT_LEN-1:0]   mul_s[ GRID_SIZE ]; // 132 x 25b

   logic [GRID_BIT_LEN:0]    grid_sum[GRID_SIZE]; // 132 x 26b 
   logic [BIT_LEN-1:0]       reduced_grid_sum[GRID_SIZE]; // 132 x 17b
   logic [BIT_LEN-1:0]       reduced_grid_sum_reg[GRID_SIZE]; // 132 x 17b
 

   logic [5:0]               lut_addr0[ACC_ELEMENTS]; // 32 x 6b -- LBS6 of lower V54 words
   logic [5:0]               lut_addr1[ACC_ELEMENTS]; // 32 x 6b -- CSB6 of lower V54 words
   logic [5:0]               lut_addr2[ACC_ELEMENTS]; // 32 x 6b -- MSB5 of lower V54 words
   logic [8:0]               lut_addr3[ACC_ELEMENTS]; // 32 x 9b -- LSB9 of lower V54 words
   logic [8:0]               lut_addr4[ACC_ELEMENTS]; // 32 x 9b -- MSB9 of lower V54 words
   logic [8:0]               lut_addr5[ACC_ELEMENTS]; // 36 x 9b -- LSB9 of Upper V76 words
   logic [8:0]               lut_addr6[ACC_ELEMENTS]; // 36 x 9b -- MSB9 of upper V76 words
   logic [BIT_LEN-1:0]       lut_data0[NUM_ELEMENTS][ACC_ELEMENTS]; // 66 words (of 36 luts) of 17b
   logic [BIT_LEN-1:0]       lut_data1[NUM_ELEMENTS][ACC_ELEMENTS]; // 66 words (of 36 luts) of 17b
   logic [BIT_LEN-1:0]       lut_data2[NUM_ELEMENTS][ACC_ELEMENTS]; // 66 words (of 36 luts) of 17b
   logic [BIT_LEN-1:0]       lut_data3[NUM_ELEMENTS][ACC_ELEMENTS]; // 66 words (of 36 luts) of 17b
   logic [BIT_LEN-1:0]       lut_data4[NUM_ELEMENTS][ACC_ELEMENTS]; // 66 words (of 36 luts) of 17b
   logic [BIT_LEN-1:0]       lut_data5[NUM_ELEMENTS][ACC_ELEMENTS]; // 66 words (of 36 luts) of 17b
   logic [BIT_LEN-1:0]       lut_data6[NUM_ELEMENTS][ACC_ELEMENTS]; // 66 words (of 36 luts) of 17b

   logic [ACC_BIT_LEN-1:0]   acc_stack[NUM_ELEMENTS][153]; // 66 sumation columns
   logic [ACC_BIT_LEN-1:0]   acc_C[NUM_ELEMENTS]; // 66 words of 17+12=25b
   logic [ACC_BIT_LEN-1:0]   acc_S[NUM_ELEMENTS]; // 66 words of 17+12=25b

   logic [ACC_BIT_LEN:0]     acc_sum[NUM_ELEMENTS]; // 66 column sums of 26b
   logic [BIT_LEN-1:0]       reduced_acc_sum[NUM_ELEMENTS]; // 66 column sums of 17b

   logic                     out_valid;

   // State machine setting values based on current cycle
   always_comb begin
      next_cycle                  = '0;
      out_valid                   = 1'b0;
      if (reset) begin
         next_cycle               = '0;
         next_cycle[IDLE]         = 1'b1;
         out_valid                = 1'b0;
      end
      else begin
         unique case(1'b1)
            curr_cycle[IDLE]: begin
               if (start) begin
                  next_cycle[PRECYC_0]      = 1'b1;
               end
               else begin
                  next_cycle[IDLE]         = 1'b1;
               end
            end
            curr_cycle[PRECYC_0] : begin next_cycle[PRECYC_1] = 1'b1; end
            curr_cycle[PRECYC_1] : begin next_cycle[PRECYC_2] = 1'b1; end
            curr_cycle[PRECYC_2] : begin next_cycle[PRECYC_3] = 1'b1; end
            curr_cycle[PRECYC_3] : begin next_cycle[PRECYC_4]  = 1'b1; end
            curr_cycle[PRECYC_4] : begin next_cycle[PRECYC_5]  = 1'b1; end
            curr_cycle[PRECYC_5] : begin next_cycle[PRECYC_6]  = 1'b1; end
            curr_cycle[PRECYC_6] : begin next_cycle[CYCLE_0]  = 1'b1; end
            curr_cycle[CYCLE_0] : begin 
              if( power_ok ) begin
                next_cycle[CYCLE_1] = 1'b1; 
              end else begin
                next_cycle[CYCLE_0] = 1'b1;
              end
            end
            curr_cycle[CYCLE_1] : begin next_cycle[CYCLE_2] = 1'b1; end
            curr_cycle[CYCLE_2] : begin next_cycle[CYCLE_3] = 1'b1; end
            curr_cycle[CYCLE_3] : begin 
              if( power_ok ) begin
                next_cycle[CYCLE_4B] = 1'b1; 
              end else begin
                next_cycle[CYCLE_4] = 1'b1; 
              end
            end
            curr_cycle[CYCLE_4] : begin 
              if( power_ok ) begin
                next_cycle[CYCLE_5] = 1'b1; 
              end else begin
                next_cycle[CYCLE_4] = 1'b1;
              end
            end
            curr_cycle[CYCLE_4B] : begin next_cycle[CYCLE_5] = 1'b1; end
            curr_cycle[CYCLE_5] : begin next_cycle[CYCLE_6] = 1'b1; end
            curr_cycle[CYCLE_6] : begin next_cycle[CYCLE_0] = 1'b1; out_valid = 1; end
         endcase
      end
   end

   // Drive output valid signal
   // Flop incoming start signal and data
   always_ff @(posedge clk) begin
      if (reset) begin
         valid                       <= 1'b0;
         start_d1                    <= 1'b0;
         power_count                 <= 21'b0;
         energy_error                <= 21'b0;
      end
      else begin
         valid                       <= out_valid;
         start_d1                    <= start || (start_d1 && ~out_valid);
         power_count  <= power_count  + (( power_count < MAX_POWER ) ? POWER_RAMP : 0 ); 
         energy_error <= energy_error + power_count - ( power_ok ? PULSE_ENERGY : 0 );
      end
      curr_cycle                     <= next_cycle;
      if (start) begin
         for (int k=0; k<NUM_ELEMENTS; k=k+1) begin
            sq_in_d1[k][BIT_LEN-1:0] <= sq_in[k][BIT_LEN-1:0];
         end 
      end
   end

   assign power_ok = ( energy_error >= PULSE_ENERGY ) ? 1'b1 : 1'b0;
   
   // Mux square input from external or loopback
   always_comb begin
      for (int k=0; k<NUM_ELEMENTS; k=k+1) begin
         curr_sq_in[k][BIT_LEN-1:0]    = sq_out[k][BIT_LEN-1:0];
         if (start_d1) begin
            curr_sq_in[k][BIT_LEN-1:0] = sq_in_d1[k][BIT_LEN-1:0];
         end
      end
   end

   square #(.NUM_ELEMENTS( 66 ),
              .BIT_LEN(    17 ),
              .WORD_LEN(   16 )
             )
      square_ (
                .clk( clk ), // TODO: removed this unused port, and then restore again when pipelining the design
                .A( curr_sq_in ),
                .C( mul_c ),
                .S( mul_s )
               );

   // Carry propogate add each column in grid
   // Partially reduce adding neighbor carries
   always_comb begin
      for (int k=0; k<GRID_SIZE; k=k+1) begin
         grid_sum[k][GRID_BIT_LEN:0] = mul_c[k][GRID_BIT_LEN-1:0] + 
                                       mul_s[k][GRID_BIT_LEN-1:0];
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
      if( curr_cycle[CYCLE_2] ) begin
         reduced_grid_sum_reg <= reduced_grid_sum;
      end
   end

   // Set values for which segments to lookup in reduction LUTs
   always_comb begin
      for (int k=0; k<ACC_ELEMENTS; k=k+1) begin
         lut_addr0[k][5:0] = {       reduced_grid_sum[k+64][ 5: 0]}; // LBS6 of lower V54 words
         lut_addr1[k][5:0] = {       reduced_grid_sum[k+64][11: 6]}; // CSB6 of lower V54 words
         lut_addr2[k][5:0] = { 1'b0, reduced_grid_sum[k+64][16:12]}; // MSB5 of lower V54 words
         lut_addr3[k][8:0] = { 1'b0, reduced_grid_sum[k+64][ 7: 0]}; // LSB8 of Upper V54 words
         lut_addr4[k][8:0] = {       reduced_grid_sum[k+64][16: 8]}; // MSB9 of upper V54 words
         lut_addr5[k][8:0] = { 1'b0, reduced_grid_sum[k+96][ 7: 0]}; // LSB8 of Upper V76 words
         lut_addr6[k][8:0] = {       reduced_grid_sum[k+96][16: 8]}; // MSB9 of upper V76 words
      end
   end
   
   // Instantiate memory holding reduction LUTs
   full_reduction_lut reduction_lut_ (
                     .ren( curr_cycle[CYCLE_2] ), // enable Lut regs
                     .clk( clk ), // brams must be clocked, but not lutrams :)
                     .lut4_lsb_addr( lut_addr0 ),
                     .lut4_csb_addr( lut_addr1 ),
                     .lut4_msb_addr( lut_addr2 ),
                     .lut5_lsb_addr( lut_addr3 ),
                     .lut5_msb_addr( lut_addr4 ),
                     .lut76_lsb_addr( lut_addr5 ),
                     .lut76_msb_addr( lut_addr6 ),
                     .lut4_lsb_data( lut_data0 ), // use 16 luts
                     .lut4_csb_data( lut_data1 ), // use 16 luts
                     .lut4_msb_data( lut_data2 ), // use 16 luts
                     .lut5_lsb_data( lut_data3 ), // 16 luts, addr reg
                     .lut5_msb_data( lut_data4 ),  // 16 luts, addr reg
                     .lut76_lsb_data( lut_data5 ), // 36 luts, addr reg
                     .lut76_msb_data( lut_data6 )  // 36 luts, addr reg
                    );


   always_comb begin
      // zero acc array   
      for (int k=0; k<NUM_ELEMENTS; k=k+1) begin
         for (int j=0; j<153; j=j+1) begin
            acc_stack[k][j][ACC_BIT_LEN-1:0] = 0;
         end
      end
      
      // V4 have 3 sets of 16 entries each
      for (int k=0; k<NUM_ELEMENTS; k=k+1) begin
         for (int j=0; j<16; j=j+1) begin
            acc_stack[k][j+  0][ACC_BIT_LEN-1:0] = {{ACC_EXTRA_BIT_LEN{1'b0}}, lut_data0[k][j][BIT_LEN-1:0]};
            acc_stack[k][j+ 16][ACC_BIT_LEN-1:0] = {{ACC_EXTRA_BIT_LEN{1'b0}}, lut_data1[k][j][BIT_LEN-1:0]};
            acc_stack[k][j+ 32][ACC_BIT_LEN-1:0] = {{ACC_EXTRA_BIT_LEN{1'b0}}, lut_data2[k][j][BIT_LEN-1:0]};
         end
      end
      
      // V54 have 2 sets 16 entries each (use upper channels
      for (int k=0; k<NUM_ELEMENTS; k=k+1) begin
         for (int j=0; j<16; j=j+1) begin
            acc_stack[k][j+ 48][ACC_BIT_LEN-1:0] = {{ACC_EXTRA_BIT_LEN{1'b0}}, lut_data3[k][j+16][BIT_LEN-1:0]};
            acc_stack[k][j+ 64][ACC_BIT_LEN-1:0] = {{ACC_EXTRA_BIT_LEN{1'b0}}, lut_data4[k][j+16][BIT_LEN-1:0]};
         end
      end
 
      // V76 have 2 sets 36 entries each
      for (int k=0; k<NUM_ELEMENTS; k=k+1) begin
         for (int j=0; j<36; j=j+1) begin
            acc_stack[k][j+ 80][ACC_BIT_LEN-1:0] = {{ACC_EXTRA_BIT_LEN{1'b0}}, lut_data5[k][j][BIT_LEN-1:0]};
            acc_stack[k][j+116][ACC_BIT_LEN-1:0] = {{ACC_EXTRA_BIT_LEN{1'b0}}, lut_data6[k][j][BIT_LEN-1:0]};
         end
      end
      // V30 has 32 entries (as all other bits go into modulus calc) and only the 64 words are used
      for (int k=0; k<NONREDUNDANT_ELEMENTS; k=k+1) begin
         acc_stack[k][152][ACC_BIT_LEN-1:0] = {{ACC_EXTRA_BIT_LEN{1'b0}}, reduced_grid_sum_reg[k][BIT_LEN-1:0]};
      end
   end

   // Instantiate compressor trees to accumulate over accumulator columns
   genvar i;
   
   generate
      for (i=0; i<NUM_ELEMENTS; i=i+1) begin : final_acc
//         compressor_tree_3_to_2 #(.NUM_ELEMENTS( 205 ), // V54(32x) lsb, csb, msb, V76(36x) lsb, csb. msb, V30
//                                  .BIT_LEN(ACC_BIT_LEN)
//                                 )
//            compressor_tree_3_to_2 (
//                                    .terms(acc_stack[i]),
//                                    .C(acc_C[i]),
//                                    .S(acc_S[i])
//                                   );
            assign acc_C[i] = 0;
            adder_tree_2_to_1 #(
                .NUM_ELEMENTS( 153 ), // V4(16x) lsb, csb, msb, V5 (16x) lsb, msb V76(36x) lsb, msb, V30
                .BIT_LEN(ACC_BIT_LEN)
            ) adder_tree_2_to_1 (
                .terms(acc_stack[i]),
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

   // Always Flop output
   always_ff @(posedge clk) begin
      if( curr_cycle[CYCLE_6] ) begin
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

module square
   #(
     parameter int NUM_ELEMENTS    = 66,
     parameter int BIT_LEN         = 17,
     parameter int WORD_LEN        = 16,

     parameter int MUL_OUT_BIT_LEN  = (2*BIT_LEN),                       // 34b
     parameter int COL_BIT_LEN      = (MUL_OUT_BIT_LEN - WORD_LEN + 1),  // 19b include 1 for AB<<1
     parameter int EXTRA_TREE_BITS  = 7,                                 // 7 bit for sum of 66 max  
     parameter int OUT_BIT_LEN      = COL_BIT_LEN + EXTRA_TREE_BITS      // 26b is our per column data path width
    )
   (
    input  logic                       clk,
    input  logic [BIT_LEN-1:0]         A[NUM_ELEMENTS],      //  66 x 17b
    output logic [OUT_BIT_LEN-1:0]     C[NUM_ELEMENTS*2],    // 132 x 26b
    output logic [OUT_BIT_LEN-1:0]     S[NUM_ELEMENTS*2]     // 132 x 26b
   );

   localparam int GRID_PAD_SHORT   = EXTRA_TREE_BITS;                             // +7b padding
   localparam int GRID_PAD_LONG    = (COL_BIT_LEN - WORD_LEN) + EXTRA_TREE_BITS;  // +10b padding

   logic [MUL_OUT_BIT_LEN-1:0] mul_result[NUM_ELEMENTS*NUM_ELEMENTS];  // 66*66 = 4356 x 34b ( ~150K wires )
   logic [OUT_BIT_LEN-1:0]     grid[NUM_ELEMENTS*2][NUM_ELEMENTS*2];   // 132 rows of 132 columns x 29b ( ~500K wires! )

   // Instantiate the diagonal upper half of the multiplier array  ( only 2211 multipliers )
   genvar x, y;
   generate
      for (y=0; y<NUM_ELEMENTS; y=y+1) begin 
         for (x=y; x<NUM_ELEMENTS; x=x+1) begin // Diagonal matrix
            async_multiplier #(.A_BIT_LEN(BIT_LEN),
                         .B_BIT_LEN(BIT_LEN)
                        ) multiplier (
                                      //.clk(clk),
                                      .A(A[x][BIT_LEN-1:0]),
                                      .B(A[y][BIT_LEN-1:0]),
                                      .P(mul_result[(NUM_ELEMENTS*y)+x])
                                     );
         end
      end
   endgenerate

   int ii, jj;
   always_comb begin
      for (ii=0; ii<NUM_ELEMENTS*2; ii=ii+1) begin // Y
         for (jj=0; jj<NUM_ELEMENTS*2; jj=jj+1) begin // X
            grid[ii][jj] = 0;
         end
      end

      for (ii=0; ii<NUM_ELEMENTS; ii=ii+1) begin : grid_row // Y
         for (jj=ii; jj<NUM_ELEMENTS; jj=jj+1) begin : grid_col // X
            if( jj == ii ) begin // diagonal cases are used as is
                grid[(ii+jj)][(2*ii)]       = {{GRID_PAD_LONG{ 1'b0}},       mul_result[(NUM_ELEMENTS*ii)+jj][WORD_LEN-1       :0       ]};
                grid[(ii+jj+1)][((2*ii)+1)] = {{GRID_PAD_SHORT{1'b0}}, 1'b0, mul_result[(NUM_ELEMENTS*ii)+jj][MUL_OUT_BIT_LEN-1:WORD_LEN]};
            end else begin // all non diagonal cases are doubled
                grid[(ii+jj)][(2*ii)]       = {{GRID_PAD_LONG{ 1'b0}},       mul_result[(NUM_ELEMENTS*ii)+jj][WORD_LEN-2       :0         ], 1'b0};
                grid[(ii+jj+1)][((2*ii)+1)] = {{GRID_PAD_SHORT{1'b0}},       mul_result[(NUM_ELEMENTS*ii)+jj][MUL_OUT_BIT_LEN-1:WORD_LEN-1]};
            end
            
         end
      end
   end

   // Sum each column using compressor tree
   genvar i;
   generate
      // The first and last columns have only one entry, return in S
      always_comb begin
         C[0][OUT_BIT_LEN-1:0]                  = '0;
         S[0][OUT_BIT_LEN-1:0]                  = grid[0][0][OUT_BIT_LEN-1:0];
         C[(NUM_ELEMENTS*2)-1][OUT_BIT_LEN-1:0] = '0;
         S[(NUM_ELEMENTS*2)-1][OUT_BIT_LEN-1:0] = grid[(NUM_ELEMENTS*2)-1][(NUM_ELEMENTS*2)-1][OUT_BIT_LEN-1:0];
      end

      for (i=1; i<(NUM_ELEMENTS*2)-1; i=i+1) begin : col_sums
         localparam integer CUR_ELEMENTS = (i <  NUM_ELEMENTS) ? (i+1) : NUM_ELEMENTS*2 - i;
         localparam integer GRID_INDEX   = (i <  NUM_ELEMENTS) ? 0 : ((i - NUM_ELEMENTS)*2+1);

//         compressor_tree_3_to_2 #(.NUM_ELEMENTS(CUR_ELEMENTS),
//                                  .BIT_LEN(OUT_BIT_LEN)
//                                 )
//            compressor_tree_3_to_2 (
//               .terms(grid[i][GRID_INDEX:(GRID_INDEX + CUR_ELEMENTS - 1)]),
//               .C(C[i]),
//               .S(S[i])
//            );

        assign C[i] = 0;
        adder_tree_2_to_1 #(.NUM_ELEMENTS(CUR_ELEMENTS),
                                  .BIT_LEN(OUT_BIT_LEN)
                                 )
            adder_tree_2_to_1 (
               .terms(grid[i][GRID_INDEX:(GRID_INDEX + CUR_ELEMENTS - 1)]),
               .S(S[i])
            );

      end
   endgenerate
endmodule

module async_multiplier
   #(
     parameter int A_BIT_LEN       = 17,
     parameter int B_BIT_LEN       = 17,

     parameter int MUL_OUT_BIT_LEN = A_BIT_LEN + B_BIT_LEN
    )
   (
    input  logic [A_BIT_LEN-1:0]       A,
    input  logic [B_BIT_LEN-1:0]       B,
    output logic [MUL_OUT_BIT_LEN-1:0] P
   );

   logic [MUL_OUT_BIT_LEN-1:0] P_result;

   always_comb begin
      P_result[MUL_OUT_BIT_LEN-1:0] = A[A_BIT_LEN-1:0] * B[B_BIT_LEN-1:0];
   end

   always_comb begin
      P[MUL_OUT_BIT_LEN-1:0]  = P_result[MUL_OUT_BIT_LEN-1:0];
   end
endmodule

module adder_tree_2_to_1
   #(
     parameter int NUM_ELEMENTS      = 9,
     parameter int BIT_LEN           = 16
    )
   (
    input  logic [BIT_LEN-1:0] terms[NUM_ELEMENTS],
    output logic [BIT_LEN-1:0] S
   );


   generate
      if (NUM_ELEMENTS == 1) begin // Return value
         always_comb begin
            S[BIT_LEN-1:0] = terms[0];
         end
      end else if (NUM_ELEMENTS == 2) begin // Return value
         always_comb begin
            S[BIT_LEN-1:0] = terms[0] + terms[1];
         end
      end else begin
         localparam integer NUM_RESULTS = integer'(NUM_ELEMENTS/2) + (NUM_ELEMENTS%2);
         logic [BIT_LEN-1:0] next_level_terms[NUM_RESULTS];

         adder_tree_level #(.NUM_ELEMENTS(NUM_ELEMENTS),
                            .BIT_LEN(BIT_LEN)
         ) adder_tree_level (
                            .terms(terms),
                            .results(next_level_terms)
         );

         adder_tree_2_to_1 #(.NUM_ELEMENTS(NUM_RESULTS),
                                  .BIT_LEN(BIT_LEN)
         ) adder_tree_2_to_1 (
                                  .terms(next_level_terms),
                                  .S(S)
         );
      end
   endgenerate
endmodule


module adder_tree_level
   #(
     parameter int NUM_ELEMENTS = 3,
     parameter int BIT_LEN      = 19,

     parameter int NUM_RESULTS  = integer'(NUM_ELEMENTS/2) + (NUM_ELEMENTS%2)
    )
   (
    input  logic [BIT_LEN-1:0] terms[NUM_ELEMENTS],
    output logic [BIT_LEN-1:0] results[NUM_RESULTS]
   );

   always_comb begin
      for (int i=0; i<(NUM_ELEMENTS / 2); i++) begin
         results[i] = terms[i*2] + terms[i*2+1];
      end

      if( NUM_ELEMENTS % 2 == 1 ) begin
         results[NUM_RESULTS-1] = terms[NUM_ELEMENTS-1];
      end
   end
endmodule

/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

module full_reduction_lut
   #(
     parameter int REDUNDANT_ELEMENTS    = 2,
     parameter int NONREDUNDANT_ELEMENTS = 64,
     parameter int NUM_SEGMENTS          = 1,
     parameter int WORD_LEN              = 16,
     parameter int BIT_LEN               = 17,
     parameter int DIN_LEN               = 8,

     parameter int NUM_ELEMENTS          = REDUNDANT_ELEMENTS+NONREDUNDANT_ELEMENTS,
     parameter int LOOK_UP_WIDTH         = 6,
     parameter int EXTRA_ELEMENTS        = 2,
     parameter int LUT_NUM_ELEMENTS      = 36
    )
   (
    input  logic clk,
    input  logic ren,
    input  logic [5:0]   lut4_lsb_addr[LUT_NUM_ELEMENTS],  // V4 16 x lsb [5:0]
    input  logic [5:0]   lut4_csb_addr[LUT_NUM_ELEMENTS],  // V4 16 x csb [11:6]
    input  logic [5:0]   lut4_msb_addr[LUT_NUM_ELEMENTS],  // V4 16 x msb [16:12] - only 5 bit used
    input  logic [8:0]   lut5_lsb_addr[LUT_NUM_ELEMENTS],  // V5 16 x lsb [7:0]                    
    input  logic [8:0]   lut5_msb_addr[LUT_NUM_ELEMENTS],  // V5 16 x csb [16:8]                   
    input  logic [8:0]   lut76_lsb_addr[LUT_NUM_ELEMENTS], // V76 36 x lsb [7:0]                    
    input  logic [8:0]   lut76_msb_addr[LUT_NUM_ELEMENTS], // V76 36 x csb [16:8]                   
    
    output logic [BIT_LEN-1:0]       lut4_lsb_data[NUM_ELEMENTS][LUT_NUM_ELEMENTS],
    output logic [BIT_LEN-1:0]       lut4_csb_data[NUM_ELEMENTS][LUT_NUM_ELEMENTS],
    output logic [BIT_LEN-1:0]       lut4_msb_data[NUM_ELEMENTS][LUT_NUM_ELEMENTS],
    output logic [BIT_LEN-1:0]       lut5_lsb_data[NUM_ELEMENTS][LUT_NUM_ELEMENTS],
    output logic [BIT_LEN-1:0]       lut5_msb_data[NUM_ELEMENTS][LUT_NUM_ELEMENTS],
    output logic [BIT_LEN-1:0]       lut76_lsb_data[NUM_ELEMENTS][LUT_NUM_ELEMENTS],
    output logic [BIT_LEN-1:0]       lut76_msb_data[NUM_ELEMENTS][LUT_NUM_ELEMENTS]
   );

   // 6 bit lookups
   localparam int NUM_LUT_ENTRIES   = 2**(LOOK_UP_WIDTH);
   localparam int LUT_WIDTH         = WORD_LEN * NONREDUNDANT_ELEMENTS;

   localparam int NUM_BRAM          = LUT_NUM_ELEMENTS;

   logic [5:0]   lut4_lsb_addr_reg[LUT_NUM_ELEMENTS];
   logic [5:0]   lut4_csb_addr_reg[LUT_NUM_ELEMENTS];
   logic [5:0]   lut4_msb_addr_reg[LUT_NUM_ELEMENTS];
   logic [8:0]   lut5_lsb_addr_reg[LUT_NUM_ELEMENTS];
   logic [8:0]   lut5_msb_addr_reg[LUT_NUM_ELEMENTS];
   logic [8:0]   lut76_lsb_addr_reg[LUT_NUM_ELEMENTS];
   logic [8:0]   lut76_msb_addr_reg[LUT_NUM_ELEMENTS];
   
   logic [LUT_WIDTH-1:0]  lut4_lsb_read_data[LUT_NUM_ELEMENTS];
   logic [LUT_WIDTH-1:0]  lut4_csb_read_data[LUT_NUM_ELEMENTS];
   logic [LUT_WIDTH-1:0]  lut4_msb_read_data[LUT_NUM_ELEMENTS];
   logic [LUT_WIDTH-1:0]  lut5_lsb_read_data[LUT_NUM_ELEMENTS];
   logic [LUT_WIDTH-1:0]  lut5_msb_read_data[LUT_NUM_ELEMENTS];
   logic [LUT_WIDTH-1:0]  lut76_lsb_read_data[LUT_NUM_ELEMENTS];
   logic [LUT_WIDTH-1:0]  lut76_msb_read_data[LUT_NUM_ELEMENTS];
   
   logic [LUT_WIDTH-1:0]  lut4_lsb_read_data_bram[NUM_BRAM];
   logic [LUT_WIDTH-1:0]  lut4_csb_read_data_bram[NUM_BRAM];
   logic [LUT_WIDTH-1:0]  lut4_msb_read_data_bram[NUM_BRAM];
   logic [LUT_WIDTH-1:0]  lut5_lsb_read_data_bram[NUM_BRAM];
   logic [LUT_WIDTH-1:0]  lut5_msb_read_data_bram[NUM_BRAM];
   logic [LUT_WIDTH-1:0]  lut76_lsb_read_data_bram[NUM_BRAM];
   logic [LUT_WIDTH-1:0]  lut76_msb_read_data_bram[NUM_BRAM];
   
   logic [BIT_LEN-1:0]    lut4_lsb_output[NUM_ELEMENTS][LUT_NUM_ELEMENTS];
   logic [BIT_LEN-1:0]    lut4_csb_output[NUM_ELEMENTS][LUT_NUM_ELEMENTS];
   logic [BIT_LEN-1:0]    lut4_msb_output[NUM_ELEMENTS][LUT_NUM_ELEMENTS];
   logic [BIT_LEN-1:0]    lut5_lsb_output[NUM_ELEMENTS][LUT_NUM_ELEMENTS];
   logic [BIT_LEN-1:0]    lut5_msb_output[NUM_ELEMENTS][LUT_NUM_ELEMENTS];
   logic [BIT_LEN-1:0]    lut76_lsb_output[NUM_ELEMENTS][LUT_NUM_ELEMENTS];
   logic [BIT_LEN-1:0]    lut76_msb_output[NUM_ELEMENTS][LUT_NUM_ELEMENTS];

   // Delay to align with data from memory
    (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut5_lsb_000[256], lut5_msb_000[512], lut76_lsb_000[256], lut76_msb_000[512];
    (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut5_lsb_001[256], lut5_msb_001[512], lut76_lsb_001[256], lut76_msb_001[512];
    (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut5_lsb_002[256], lut5_msb_002[512], lut76_lsb_002[256], lut76_msb_002[512];
    (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut5_lsb_003[256], lut5_msb_003[512], lut76_lsb_003[256], lut76_msb_003[512];
    (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut5_lsb_004[256], lut5_msb_004[512], lut76_lsb_004[256], lut76_msb_004[512];
    (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut5_lsb_005[256], lut5_msb_005[512], lut76_lsb_005[256], lut76_msb_005[512];
    (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut5_lsb_006[256], lut5_msb_006[512], lut76_lsb_006[256], lut76_msb_006[512];
    (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut5_lsb_007[256], lut5_msb_007[512], lut76_lsb_007[256], lut76_msb_007[512];
    (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut5_lsb_008[256], lut5_msb_008[512], lut76_lsb_008[256], lut76_msb_008[512];
    (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut5_lsb_009[256], lut5_msb_009[512], lut76_lsb_009[256], lut76_msb_009[512];
    (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut5_lsb_010[256], lut5_msb_010[512], lut76_lsb_010[256], lut76_msb_010[512];
    (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut5_lsb_011[256], lut5_msb_011[512], lut76_lsb_011[256], lut76_msb_011[512];
    (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut5_lsb_012[256], lut5_msb_012[512], lut76_lsb_012[256], lut76_msb_012[512];
    (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut5_lsb_013[256], lut5_msb_013[512], lut76_lsb_013[256], lut76_msb_013[512];
    (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut5_lsb_014[256], lut5_msb_014[512], lut76_lsb_014[256], lut76_msb_014[512];
    (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut5_lsb_015[256], lut5_msb_015[512], lut76_lsb_015[256], lut76_msb_015[512];
    (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut5_lsb_016[256], lut5_msb_016[512], lut76_lsb_016[256], lut76_msb_016[512];
    (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut5_lsb_017[256], lut5_msb_017[512], lut76_lsb_017[256], lut76_msb_017[512];
    (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut5_lsb_018[256], lut5_msb_018[512], lut76_lsb_018[256], lut76_msb_018[512];
    (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut5_lsb_019[256], lut5_msb_019[512], lut76_lsb_019[256], lut76_msb_019[512];
    (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut5_lsb_020[256], lut5_msb_020[512], lut76_lsb_020[256], lut76_msb_020[512];
    (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut5_lsb_021[256], lut5_msb_021[512], lut76_lsb_021[256], lut76_msb_021[512];
    (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut5_lsb_022[256], lut5_msb_022[512], lut76_lsb_022[256], lut76_msb_022[512];
    (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut5_lsb_023[256], lut5_msb_023[512], lut76_lsb_023[256], lut76_msb_023[512];
    (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut5_lsb_024[256], lut5_msb_024[512], lut76_lsb_024[256], lut76_msb_024[512];
    (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut5_lsb_025[256], lut5_msb_025[512], lut76_lsb_025[256], lut76_msb_025[512];
    (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut5_lsb_026[256], lut5_msb_026[512], lut76_lsb_026[256], lut76_msb_026[512];
    (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut5_lsb_027[256], lut5_msb_027[512], lut76_lsb_027[256], lut76_msb_027[512];
    (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut5_lsb_028[256], lut5_msb_028[512], lut76_lsb_028[256], lut76_msb_028[512];
    (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut5_lsb_029[256], lut5_msb_029[512], lut76_lsb_029[256], lut76_msb_029[512];
    (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut5_lsb_030[256], lut5_msb_030[512], lut76_lsb_030[256], lut76_msb_030[512];
    (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut5_lsb_031[256], lut5_msb_031[512], lut76_lsb_031[256], lut76_msb_031[512];
    (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut5_lsb_032[256], lut5_msb_032[512], lut76_lsb_032[256], lut76_msb_032[512];
    (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut5_lsb_033[256], lut5_msb_033[512], lut76_lsb_033[256], lut76_msb_033[512];
    (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut5_lsb_034[256], lut5_msb_034[512], lut76_lsb_034[256], lut76_msb_034[512];
    (* rom_style = "block" *) logic [LUT_WIDTH-1:0] lut5_lsb_035[256], lut5_msb_035[512], lut76_lsb_035[256], lut76_msb_035[512];

    (* rom_style = "distributed" *) logic [LUT_WIDTH-1:0] lut4_lsb_000[64], lut4_csb_000[64], lut4_msb_000[32];
    (* rom_style = "distributed" *) logic [LUT_WIDTH-1:0] lut4_lsb_001[64], lut4_csb_001[64], lut4_msb_001[32];
    (* rom_style = "distributed" *) logic [LUT_WIDTH-1:0] lut4_lsb_002[64], lut4_csb_002[64], lut4_msb_002[32];
    (* rom_style = "distributed" *) logic [LUT_WIDTH-1:0] lut4_lsb_003[64], lut4_csb_003[64], lut4_msb_003[32];
    (* rom_style = "distributed" *) logic [LUT_WIDTH-1:0] lut4_lsb_004[64], lut4_csb_004[64], lut4_msb_004[32];
    (* rom_style = "distributed" *) logic [LUT_WIDTH-1:0] lut4_lsb_005[64], lut4_csb_005[64], lut4_msb_005[32];
    (* rom_style = "distributed" *) logic [LUT_WIDTH-1:0] lut4_lsb_006[64], lut4_csb_006[64], lut4_msb_006[32];
    (* rom_style = "distributed" *) logic [LUT_WIDTH-1:0] lut4_lsb_007[64], lut4_csb_007[64], lut4_msb_007[32];
    (* rom_style = "distributed" *) logic [LUT_WIDTH-1:0] lut4_lsb_008[64], lut4_csb_008[64], lut4_msb_008[32];
    (* rom_style = "distributed" *) logic [LUT_WIDTH-1:0] lut4_lsb_009[64], lut4_csb_009[64], lut4_msb_009[32];
    (* rom_style = "distributed" *) logic [LUT_WIDTH-1:0] lut4_lsb_010[64], lut4_csb_010[64], lut4_msb_010[32];
    (* rom_style = "distributed" *) logic [LUT_WIDTH-1:0] lut4_lsb_011[64], lut4_csb_011[64], lut4_msb_011[32];
    (* rom_style = "distributed" *) logic [LUT_WIDTH-1:0] lut4_lsb_012[64], lut4_csb_012[64], lut4_msb_012[32];
    (* rom_style = "distributed" *) logic [LUT_WIDTH-1:0] lut4_lsb_013[64], lut4_csb_013[64], lut4_msb_013[32];
    (* rom_style = "distributed" *) logic [LUT_WIDTH-1:0] lut4_lsb_014[64], lut4_csb_014[64], lut4_msb_014[32];
    (* rom_style = "distributed" *) logic [LUT_WIDTH-1:0] lut4_lsb_015[64], lut4_csb_015[64], lut4_msb_015[32];
    (* rom_style = "distributed" *) logic [LUT_WIDTH-1:0] lut4_lsb_016[64], lut4_csb_016[64], lut4_msb_016[32];
    (* rom_style = "distributed" *) logic [LUT_WIDTH-1:0] lut4_lsb_017[64], lut4_csb_017[64], lut4_msb_017[32];
    (* rom_style = "distributed" *) logic [LUT_WIDTH-1:0] lut4_lsb_018[64], lut4_csb_018[64], lut4_msb_018[32];
    (* rom_style = "distributed" *) logic [LUT_WIDTH-1:0] lut4_lsb_019[64], lut4_csb_019[64], lut4_msb_019[32];
    (* rom_style = "distributed" *) logic [LUT_WIDTH-1:0] lut4_lsb_020[64], lut4_csb_020[64], lut4_msb_020[32];
    (* rom_style = "distributed" *) logic [LUT_WIDTH-1:0] lut4_lsb_021[64], lut4_csb_021[64], lut4_msb_021[32];
    (* rom_style = "distributed" *) logic [LUT_WIDTH-1:0] lut4_lsb_022[64], lut4_csb_022[64], lut4_msb_022[32];
    (* rom_style = "distributed" *) logic [LUT_WIDTH-1:0] lut4_lsb_023[64], lut4_csb_023[64], lut4_msb_023[32];
    (* rom_style = "distributed" *) logic [LUT_WIDTH-1:0] lut4_lsb_024[64], lut4_csb_024[64], lut4_msb_024[32];
    (* rom_style = "distributed" *) logic [LUT_WIDTH-1:0] lut4_lsb_025[64], lut4_csb_025[64], lut4_msb_025[32];
    (* rom_style = "distributed" *) logic [LUT_WIDTH-1:0] lut4_lsb_026[64], lut4_csb_026[64], lut4_msb_026[32];
    (* rom_style = "distributed" *) logic [LUT_WIDTH-1:0] lut4_lsb_027[64], lut4_csb_027[64], lut4_msb_027[32];
    (* rom_style = "distributed" *) logic [LUT_WIDTH-1:0] lut4_lsb_028[64], lut4_csb_028[64], lut4_msb_028[32];
    (* rom_style = "distributed" *) logic [LUT_WIDTH-1:0] lut4_lsb_029[64], lut4_csb_029[64], lut4_msb_029[32];
    (* rom_style = "distributed" *) logic [LUT_WIDTH-1:0] lut4_lsb_030[64], lut4_csb_030[64], lut4_msb_030[32];
    (* rom_style = "distributed" *) logic [LUT_WIDTH-1:0] lut4_lsb_031[64], lut4_csb_031[64], lut4_msb_031[32];
    (* rom_style = "distributed" *) logic [LUT_WIDTH-1:0] lut4_lsb_032[64], lut4_csb_032[64], lut4_msb_032[32];
    (* rom_style = "distributed" *) logic [LUT_WIDTH-1:0] lut4_lsb_033[64], lut4_csb_033[64], lut4_msb_033[32];
    (* rom_style = "distributed" *) logic [LUT_WIDTH-1:0] lut4_lsb_034[64], lut4_csb_034[64], lut4_msb_034[32];
    (* rom_style = "distributed" *) logic [LUT_WIDTH-1:0] lut4_lsb_035[64], lut4_csb_035[64], lut4_msb_035[32];

   initial begin
      $readmemh("reduction_lut_54_000.dat", lut4_lsb_000);
      $readmemh("reduction_lut_54_001.dat", lut4_lsb_001);
      $readmemh("reduction_lut_54_002.dat", lut4_lsb_002);
      $readmemh("reduction_lut_54_003.dat", lut4_lsb_003);
      $readmemh("reduction_lut_54_004.dat", lut4_lsb_004);
      $readmemh("reduction_lut_54_005.dat", lut4_lsb_005);
      $readmemh("reduction_lut_54_006.dat", lut4_lsb_006);
      $readmemh("reduction_lut_54_007.dat", lut4_lsb_007);
      $readmemh("reduction_lut_54_008.dat", lut4_lsb_008);
      $readmemh("reduction_lut_54_009.dat", lut4_lsb_009);
      $readmemh("reduction_lut_54_010.dat", lut4_lsb_010);
      $readmemh("reduction_lut_54_011.dat", lut4_lsb_011);
      $readmemh("reduction_lut_54_012.dat", lut4_lsb_012);
      $readmemh("reduction_lut_54_013.dat", lut4_lsb_013);
      $readmemh("reduction_lut_54_014.dat", lut4_lsb_014);
      $readmemh("reduction_lut_54_015.dat", lut4_lsb_015);
      $readmemh("reduction_lut_54_016.dat", lut4_lsb_016);
      $readmemh("reduction_lut_54_017.dat", lut4_lsb_017);
      $readmemh("reduction_lut_54_018.dat", lut4_lsb_018);
      $readmemh("reduction_lut_54_019.dat", lut4_lsb_019);
      $readmemh("reduction_lut_54_020.dat", lut4_lsb_020);
      $readmemh("reduction_lut_54_021.dat", lut4_lsb_021);
      $readmemh("reduction_lut_54_022.dat", lut4_lsb_022);
      $readmemh("reduction_lut_54_023.dat", lut4_lsb_023);
      $readmemh("reduction_lut_54_024.dat", lut4_lsb_024);
      $readmemh("reduction_lut_54_025.dat", lut4_lsb_025);
      $readmemh("reduction_lut_54_026.dat", lut4_lsb_026);
      $readmemh("reduction_lut_54_027.dat", lut4_lsb_027);
      $readmemh("reduction_lut_54_028.dat", lut4_lsb_028);
      $readmemh("reduction_lut_54_029.dat", lut4_lsb_029);
      $readmemh("reduction_lut_54_030.dat", lut4_lsb_030);
      $readmemh("reduction_lut_54_031.dat", lut4_lsb_031);
      $readmemh("reduction_lut_54_032.dat", lut4_lsb_032);
      $readmemh("reduction_lut_54_033.dat", lut4_lsb_033);
      $readmemh("reduction_lut_54_034.dat", lut4_lsb_034);
      $readmemh("reduction_lut_54_035.dat", lut4_lsb_035);

      $readmemh("reduction_lut_54_000.dat", lut4_csb_000);
      $readmemh("reduction_lut_54_001.dat", lut4_csb_001);
      $readmemh("reduction_lut_54_002.dat", lut4_csb_002);
      $readmemh("reduction_lut_54_003.dat", lut4_csb_003);
      $readmemh("reduction_lut_54_004.dat", lut4_csb_004);
      $readmemh("reduction_lut_54_005.dat", lut4_csb_005);
      $readmemh("reduction_lut_54_006.dat", lut4_csb_006);
      $readmemh("reduction_lut_54_007.dat", lut4_csb_007);
      $readmemh("reduction_lut_54_008.dat", lut4_csb_008);
      $readmemh("reduction_lut_54_009.dat", lut4_csb_009);
      $readmemh("reduction_lut_54_010.dat", lut4_csb_010);
      $readmemh("reduction_lut_54_011.dat", lut4_csb_011);
      $readmemh("reduction_lut_54_012.dat", lut4_csb_012);
      $readmemh("reduction_lut_54_013.dat", lut4_csb_013);
      $readmemh("reduction_lut_54_014.dat", lut4_csb_014);
      $readmemh("reduction_lut_54_015.dat", lut4_csb_015);
      $readmemh("reduction_lut_54_016.dat", lut4_csb_016);
      $readmemh("reduction_lut_54_017.dat", lut4_csb_017);
      $readmemh("reduction_lut_54_018.dat", lut4_csb_018);
      $readmemh("reduction_lut_54_019.dat", lut4_csb_019);
      $readmemh("reduction_lut_54_020.dat", lut4_csb_020);
      $readmemh("reduction_lut_54_021.dat", lut4_csb_021);
      $readmemh("reduction_lut_54_022.dat", lut4_csb_022);
      $readmemh("reduction_lut_54_023.dat", lut4_csb_023);
      $readmemh("reduction_lut_54_024.dat", lut4_csb_024);
      $readmemh("reduction_lut_54_025.dat", lut4_csb_025);
      $readmemh("reduction_lut_54_026.dat", lut4_csb_026);
      $readmemh("reduction_lut_54_027.dat", lut4_csb_027);
      $readmemh("reduction_lut_54_028.dat", lut4_csb_028);
      $readmemh("reduction_lut_54_029.dat", lut4_csb_029);
      $readmemh("reduction_lut_54_030.dat", lut4_csb_030);
      $readmemh("reduction_lut_54_031.dat", lut4_csb_031);
      $readmemh("reduction_lut_54_032.dat", lut4_csb_032);
      $readmemh("reduction_lut_54_033.dat", lut4_csb_033);
      $readmemh("reduction_lut_54_034.dat", lut4_csb_034);
      $readmemh("reduction_lut_54_035.dat", lut4_csb_035);

      $readmemh("reduction_lut_54_000.dat", lut4_msb_000);
      $readmemh("reduction_lut_54_001.dat", lut4_msb_001);
      $readmemh("reduction_lut_54_002.dat", lut4_msb_002);
      $readmemh("reduction_lut_54_003.dat", lut4_msb_003);
      $readmemh("reduction_lut_54_004.dat", lut4_msb_004);
      $readmemh("reduction_lut_54_005.dat", lut4_msb_005);
      $readmemh("reduction_lut_54_006.dat", lut4_msb_006);
      $readmemh("reduction_lut_54_007.dat", lut4_msb_007);
      $readmemh("reduction_lut_54_008.dat", lut4_msb_008);
      $readmemh("reduction_lut_54_009.dat", lut4_msb_009);
      $readmemh("reduction_lut_54_010.dat", lut4_msb_010);
      $readmemh("reduction_lut_54_011.dat", lut4_msb_011);
      $readmemh("reduction_lut_54_012.dat", lut4_msb_012);
      $readmemh("reduction_lut_54_013.dat", lut4_msb_013);
      $readmemh("reduction_lut_54_014.dat", lut4_msb_014);
      $readmemh("reduction_lut_54_015.dat", lut4_msb_015);
      $readmemh("reduction_lut_54_016.dat", lut4_msb_016);
      $readmemh("reduction_lut_54_017.dat", lut4_msb_017);
      $readmemh("reduction_lut_54_018.dat", lut4_msb_018);
      $readmemh("reduction_lut_54_019.dat", lut4_msb_019);
      $readmemh("reduction_lut_54_020.dat", lut4_msb_020);
      $readmemh("reduction_lut_54_021.dat", lut4_msb_021);
      $readmemh("reduction_lut_54_022.dat", lut4_msb_022);
      $readmemh("reduction_lut_54_023.dat", lut4_msb_023);
      $readmemh("reduction_lut_54_024.dat", lut4_msb_024);
      $readmemh("reduction_lut_54_025.dat", lut4_msb_025);
      $readmemh("reduction_lut_54_026.dat", lut4_msb_026);
      $readmemh("reduction_lut_54_027.dat", lut4_msb_027);
      $readmemh("reduction_lut_54_028.dat", lut4_msb_028);
      $readmemh("reduction_lut_54_029.dat", lut4_msb_029);
      $readmemh("reduction_lut_54_030.dat", lut4_msb_030);
      $readmemh("reduction_lut_54_031.dat", lut4_msb_031);
      $readmemh("reduction_lut_54_032.dat", lut4_msb_032);
      $readmemh("reduction_lut_54_033.dat", lut4_msb_033);
      $readmemh("reduction_lut_54_034.dat", lut4_msb_034);
      $readmemh("reduction_lut_54_035.dat", lut4_msb_035);

      $readmemh("reduction_lut_54_000.dat", lut5_lsb_000);
      $readmemh("reduction_lut_54_001.dat", lut5_lsb_001);
      $readmemh("reduction_lut_54_002.dat", lut5_lsb_002);
      $readmemh("reduction_lut_54_003.dat", lut5_lsb_003);
      $readmemh("reduction_lut_54_004.dat", lut5_lsb_004);
      $readmemh("reduction_lut_54_005.dat", lut5_lsb_005);
      $readmemh("reduction_lut_54_006.dat", lut5_lsb_006);
      $readmemh("reduction_lut_54_007.dat", lut5_lsb_007);
      $readmemh("reduction_lut_54_008.dat", lut5_lsb_008);
      $readmemh("reduction_lut_54_009.dat", lut5_lsb_009);
      $readmemh("reduction_lut_54_010.dat", lut5_lsb_010);
      $readmemh("reduction_lut_54_011.dat", lut5_lsb_011);
      $readmemh("reduction_lut_54_012.dat", lut5_lsb_012);
      $readmemh("reduction_lut_54_013.dat", lut5_lsb_013);
      $readmemh("reduction_lut_54_014.dat", lut5_lsb_014);
      $readmemh("reduction_lut_54_015.dat", lut5_lsb_015);
      $readmemh("reduction_lut_54_016.dat", lut5_lsb_016);
      $readmemh("reduction_lut_54_017.dat", lut5_lsb_017);
      $readmemh("reduction_lut_54_018.dat", lut5_lsb_018);
      $readmemh("reduction_lut_54_019.dat", lut5_lsb_019);
      $readmemh("reduction_lut_54_020.dat", lut5_lsb_020);
      $readmemh("reduction_lut_54_021.dat", lut5_lsb_021);
      $readmemh("reduction_lut_54_022.dat", lut5_lsb_022);
      $readmemh("reduction_lut_54_023.dat", lut5_lsb_023);
      $readmemh("reduction_lut_54_024.dat", lut5_lsb_024);
      $readmemh("reduction_lut_54_025.dat", lut5_lsb_025);
      $readmemh("reduction_lut_54_026.dat", lut5_lsb_026);
      $readmemh("reduction_lut_54_027.dat", lut5_lsb_027);
      $readmemh("reduction_lut_54_028.dat", lut5_lsb_028);
      $readmemh("reduction_lut_54_029.dat", lut5_lsb_029);
      $readmemh("reduction_lut_54_030.dat", lut5_lsb_030);
      $readmemh("reduction_lut_54_031.dat", lut5_lsb_031);
      $readmemh("reduction_lut_54_032.dat", lut5_lsb_032);
      $readmemh("reduction_lut_54_033.dat", lut5_lsb_033);
      $readmemh("reduction_lut_54_034.dat", lut5_lsb_034);
      $readmemh("reduction_lut_54_035.dat", lut5_lsb_035);

      $readmemh("reduction_lut_54_000.dat", lut5_msb_000);
      $readmemh("reduction_lut_54_001.dat", lut5_msb_001);
      $readmemh("reduction_lut_54_002.dat", lut5_msb_002);
      $readmemh("reduction_lut_54_003.dat", lut5_msb_003);
      $readmemh("reduction_lut_54_004.dat", lut5_msb_004);
      $readmemh("reduction_lut_54_005.dat", lut5_msb_005);
      $readmemh("reduction_lut_54_006.dat", lut5_msb_006);
      $readmemh("reduction_lut_54_007.dat", lut5_msb_007);
      $readmemh("reduction_lut_54_008.dat", lut5_msb_008);
      $readmemh("reduction_lut_54_009.dat", lut5_msb_009);
      $readmemh("reduction_lut_54_010.dat", lut5_msb_010);
      $readmemh("reduction_lut_54_011.dat", lut5_msb_011);
      $readmemh("reduction_lut_54_012.dat", lut5_msb_012);
      $readmemh("reduction_lut_54_013.dat", lut5_msb_013);
      $readmemh("reduction_lut_54_014.dat", lut5_msb_014);
      $readmemh("reduction_lut_54_015.dat", lut5_msb_015);
      $readmemh("reduction_lut_54_016.dat", lut5_msb_016);
      $readmemh("reduction_lut_54_017.dat", lut5_msb_017);
      $readmemh("reduction_lut_54_018.dat", lut5_msb_018);
      $readmemh("reduction_lut_54_019.dat", lut5_msb_019);
      $readmemh("reduction_lut_54_020.dat", lut5_msb_020);
      $readmemh("reduction_lut_54_021.dat", lut5_msb_021);
      $readmemh("reduction_lut_54_022.dat", lut5_msb_022);
      $readmemh("reduction_lut_54_023.dat", lut5_msb_023);
      $readmemh("reduction_lut_54_024.dat", lut5_msb_024);
      $readmemh("reduction_lut_54_025.dat", lut5_msb_025);
      $readmemh("reduction_lut_54_026.dat", lut5_msb_026);
      $readmemh("reduction_lut_54_027.dat", lut5_msb_027);
      $readmemh("reduction_lut_54_028.dat", lut5_msb_028);
      $readmemh("reduction_lut_54_029.dat", lut5_msb_029);
      $readmemh("reduction_lut_54_030.dat", lut5_msb_030);
      $readmemh("reduction_lut_54_031.dat", lut5_msb_031);
      $readmemh("reduction_lut_54_032.dat", lut5_msb_032);
      $readmemh("reduction_lut_54_033.dat", lut5_msb_033);
      $readmemh("reduction_lut_54_034.dat", lut5_msb_034);
      $readmemh("reduction_lut_54_035.dat", lut5_msb_035);

      $readmemh("reduction_lut_76_000.dat", lut76_lsb_000);
      $readmemh("reduction_lut_76_001.dat", lut76_lsb_001);
      $readmemh("reduction_lut_76_002.dat", lut76_lsb_002);
      $readmemh("reduction_lut_76_003.dat", lut76_lsb_003);
      $readmemh("reduction_lut_76_004.dat", lut76_lsb_004);
      $readmemh("reduction_lut_76_005.dat", lut76_lsb_005);
      $readmemh("reduction_lut_76_006.dat", lut76_lsb_006);
      $readmemh("reduction_lut_76_007.dat", lut76_lsb_007);
      $readmemh("reduction_lut_76_008.dat", lut76_lsb_008);
      $readmemh("reduction_lut_76_009.dat", lut76_lsb_009);
      $readmemh("reduction_lut_76_010.dat", lut76_lsb_010);
      $readmemh("reduction_lut_76_011.dat", lut76_lsb_011);
      $readmemh("reduction_lut_76_012.dat", lut76_lsb_012);
      $readmemh("reduction_lut_76_013.dat", lut76_lsb_013);
      $readmemh("reduction_lut_76_014.dat", lut76_lsb_014);
      $readmemh("reduction_lut_76_015.dat", lut76_lsb_015);
      $readmemh("reduction_lut_76_016.dat", lut76_lsb_016);
      $readmemh("reduction_lut_76_017.dat", lut76_lsb_017);
      $readmemh("reduction_lut_76_018.dat", lut76_lsb_018);
      $readmemh("reduction_lut_76_019.dat", lut76_lsb_019);
      $readmemh("reduction_lut_76_020.dat", lut76_lsb_020);
      $readmemh("reduction_lut_76_021.dat", lut76_lsb_021);
      $readmemh("reduction_lut_76_022.dat", lut76_lsb_022);
      $readmemh("reduction_lut_76_023.dat", lut76_lsb_023);
      $readmemh("reduction_lut_76_024.dat", lut76_lsb_024);
      $readmemh("reduction_lut_76_025.dat", lut76_lsb_025);
      $readmemh("reduction_lut_76_026.dat", lut76_lsb_026);
      $readmemh("reduction_lut_76_027.dat", lut76_lsb_027);
      $readmemh("reduction_lut_76_028.dat", lut76_lsb_028);
      $readmemh("reduction_lut_76_029.dat", lut76_lsb_029);
      $readmemh("reduction_lut_76_030.dat", lut76_lsb_030);
      $readmemh("reduction_lut_76_031.dat", lut76_lsb_031);
      $readmemh("reduction_lut_76_032.dat", lut76_lsb_032);
      $readmemh("reduction_lut_76_033.dat", lut76_lsb_033);
      $readmemh("reduction_lut_76_034.dat", lut76_lsb_034);
      $readmemh("reduction_lut_76_035.dat", lut76_lsb_035);

      $readmemh("reduction_lut_76_000.dat", lut76_msb_000);
      $readmemh("reduction_lut_76_001.dat", lut76_msb_001);
      $readmemh("reduction_lut_76_002.dat", lut76_msb_002);
      $readmemh("reduction_lut_76_003.dat", lut76_msb_003);
      $readmemh("reduction_lut_76_004.dat", lut76_msb_004);
      $readmemh("reduction_lut_76_005.dat", lut76_msb_005);
      $readmemh("reduction_lut_76_006.dat", lut76_msb_006);
      $readmemh("reduction_lut_76_007.dat", lut76_msb_007);
      $readmemh("reduction_lut_76_008.dat", lut76_msb_008);
      $readmemh("reduction_lut_76_009.dat", lut76_msb_009);
      $readmemh("reduction_lut_76_010.dat", lut76_msb_010);
      $readmemh("reduction_lut_76_011.dat", lut76_msb_011);
      $readmemh("reduction_lut_76_012.dat", lut76_msb_012);
      $readmemh("reduction_lut_76_013.dat", lut76_msb_013);
      $readmemh("reduction_lut_76_014.dat", lut76_msb_014);
      $readmemh("reduction_lut_76_015.dat", lut76_msb_015);
      $readmemh("reduction_lut_76_016.dat", lut76_msb_016);
      $readmemh("reduction_lut_76_017.dat", lut76_msb_017);
      $readmemh("reduction_lut_76_018.dat", lut76_msb_018);
      $readmemh("reduction_lut_76_019.dat", lut76_msb_019);
      $readmemh("reduction_lut_76_020.dat", lut76_msb_020);
      $readmemh("reduction_lut_76_021.dat", lut76_msb_021);
      $readmemh("reduction_lut_76_022.dat", lut76_msb_022);
      $readmemh("reduction_lut_76_023.dat", lut76_msb_023);
      $readmemh("reduction_lut_76_024.dat", lut76_msb_024);
      $readmemh("reduction_lut_76_025.dat", lut76_msb_025);
      $readmemh("reduction_lut_76_026.dat", lut76_msb_026);
      $readmemh("reduction_lut_76_027.dat", lut76_msb_027);
      $readmemh("reduction_lut_76_028.dat", lut76_msb_028);
      $readmemh("reduction_lut_76_029.dat", lut76_msb_029);
      $readmemh("reduction_lut_76_030.dat", lut76_msb_030);
      $readmemh("reduction_lut_76_031.dat", lut76_msb_031);
      $readmemh("reduction_lut_76_032.dat", lut76_msb_032);
      $readmemh("reduction_lut_76_033.dat", lut76_msb_033);
      $readmemh("reduction_lut_76_034.dat", lut76_msb_034);
      $readmemh("reduction_lut_76_035.dat", lut76_msb_035);
   end
   
   always_ff @(posedge clk) begin
     if( ren ) begin
        lut4_lsb_addr_reg <= lut4_lsb_addr;
        lut4_csb_addr_reg <= lut4_csb_addr;
        lut4_msb_addr_reg <= lut4_msb_addr;
        lut5_lsb_addr_reg <= lut5_lsb_addr;
        lut5_msb_addr_reg <= lut5_msb_addr;
        lut76_lsb_addr_reg <= lut76_lsb_addr;
        lut76_msb_addr_reg <= lut76_msb_addr;
     end
   end

   always_comb begin
      lut4_lsb_read_data_bram[0]  = lut4_lsb_000[lut4_lsb_addr_reg[ 0][5:0]];
      lut4_lsb_read_data_bram[1]  = lut4_lsb_001[lut4_lsb_addr_reg[ 1][5:0]];
      lut4_lsb_read_data_bram[2]  = lut4_lsb_002[lut4_lsb_addr_reg[ 2][5:0]];
      lut4_lsb_read_data_bram[3]  = lut4_lsb_003[lut4_lsb_addr_reg[ 3][5:0]];
      lut4_lsb_read_data_bram[4]  = lut4_lsb_004[lut4_lsb_addr_reg[ 4][5:0]];
      lut4_lsb_read_data_bram[5]  = lut4_lsb_005[lut4_lsb_addr_reg[ 5][5:0]];
      lut4_lsb_read_data_bram[6]  = lut4_lsb_006[lut4_lsb_addr_reg[ 6][5:0]];
      lut4_lsb_read_data_bram[7]  = lut4_lsb_007[lut4_lsb_addr_reg[ 7][5:0]];
      lut4_lsb_read_data_bram[8]  = lut4_lsb_008[lut4_lsb_addr_reg[ 8][5:0]];
      lut4_lsb_read_data_bram[9]  = lut4_lsb_009[lut4_lsb_addr_reg[ 9][5:0]];
      lut4_lsb_read_data_bram[10] = lut4_lsb_010[lut4_lsb_addr_reg[10][5:0]];
      lut4_lsb_read_data_bram[11] = lut4_lsb_011[lut4_lsb_addr_reg[11][5:0]];
      lut4_lsb_read_data_bram[12] = lut4_lsb_012[lut4_lsb_addr_reg[12][5:0]];
      lut4_lsb_read_data_bram[13] = lut4_lsb_013[lut4_lsb_addr_reg[13][5:0]];
      lut4_lsb_read_data_bram[14] = lut4_lsb_014[lut4_lsb_addr_reg[14][5:0]];
      lut4_lsb_read_data_bram[15] = lut4_lsb_015[lut4_lsb_addr_reg[15][5:0]];
      lut4_lsb_read_data_bram[16] = 1024'b0;
      lut4_lsb_read_data_bram[17] = 1024'b0;
      lut4_lsb_read_data_bram[18] = 1024'b0;
      lut4_lsb_read_data_bram[19] = 1024'b0;
      lut4_lsb_read_data_bram[20] = 1024'b0;
      lut4_lsb_read_data_bram[21] = 1024'b0;
      lut4_lsb_read_data_bram[22] = 1024'b0;
      lut4_lsb_read_data_bram[23] = 1024'b0;
      lut4_lsb_read_data_bram[24] = 1024'b0;
      lut4_lsb_read_data_bram[25] = 1024'b0;
      lut4_lsb_read_data_bram[26] = 1024'b0;
      lut4_lsb_read_data_bram[27] = 1024'b0;
      lut4_lsb_read_data_bram[28] = 1024'b0;
      lut4_lsb_read_data_bram[29] = 1024'b0;
      lut4_lsb_read_data_bram[30] = 1024'b0;
      lut4_lsb_read_data_bram[31] = 1024'b0;
      lut4_lsb_read_data_bram[32] = 1024'b0; 
      lut4_lsb_read_data_bram[33] = 1024'b0; 
      lut4_lsb_read_data_bram[34] = 1024'b0; 
      lut4_lsb_read_data_bram[35] = 1024'b0; 

      lut4_csb_read_data_bram[0]  = lut4_csb_000[lut4_csb_addr_reg[ 0][5:0]];
      lut4_csb_read_data_bram[1]  = lut4_csb_001[lut4_csb_addr_reg[ 1][5:0]];
      lut4_csb_read_data_bram[2]  = lut4_csb_002[lut4_csb_addr_reg[ 2][5:0]];
      lut4_csb_read_data_bram[3]  = lut4_csb_003[lut4_csb_addr_reg[ 3][5:0]];
      lut4_csb_read_data_bram[4]  = lut4_csb_004[lut4_csb_addr_reg[ 4][5:0]];
      lut4_csb_read_data_bram[5]  = lut4_csb_005[lut4_csb_addr_reg[ 5][5:0]];
      lut4_csb_read_data_bram[6]  = lut4_csb_006[lut4_csb_addr_reg[ 6][5:0]];
      lut4_csb_read_data_bram[7]  = lut4_csb_007[lut4_csb_addr_reg[ 7][5:0]];
      lut4_csb_read_data_bram[8]  = lut4_csb_008[lut4_csb_addr_reg[ 8][5:0]];
      lut4_csb_read_data_bram[9]  = lut4_csb_009[lut4_csb_addr_reg[ 9][5:0]];
      lut4_csb_read_data_bram[10] = lut4_csb_010[lut4_csb_addr_reg[10][5:0]];
      lut4_csb_read_data_bram[11] = lut4_csb_011[lut4_csb_addr_reg[11][5:0]];
      lut4_csb_read_data_bram[12] = lut4_csb_012[lut4_csb_addr_reg[12][5:0]];
      lut4_csb_read_data_bram[13] = lut4_csb_013[lut4_csb_addr_reg[13][5:0]];
      lut4_csb_read_data_bram[14] = lut4_csb_014[lut4_csb_addr_reg[14][5:0]];
      lut4_csb_read_data_bram[15] = lut4_csb_015[lut4_csb_addr_reg[15][5:0]];
      lut4_csb_read_data_bram[16] = 1024'b0;
      lut4_csb_read_data_bram[17] = 1024'b0;
      lut4_csb_read_data_bram[18] = 1024'b0;
      lut4_csb_read_data_bram[19] = 1024'b0;
      lut4_csb_read_data_bram[20] = 1024'b0;
      lut4_csb_read_data_bram[21] = 1024'b0;
      lut4_csb_read_data_bram[22] = 1024'b0;
      lut4_csb_read_data_bram[23] = 1024'b0;
      lut4_csb_read_data_bram[24] = 1024'b0;
      lut4_csb_read_data_bram[25] = 1024'b0;
      lut4_csb_read_data_bram[26] = 1024'b0;
      lut4_csb_read_data_bram[27] = 1024'b0;
      lut4_csb_read_data_bram[28] = 1024'b0;
      lut4_csb_read_data_bram[29] = 1024'b0;
      lut4_csb_read_data_bram[30] = 1024'b0;
      lut4_csb_read_data_bram[31] = 1024'b0;
      lut4_csb_read_data_bram[32] = 1024'b0; 
      lut4_csb_read_data_bram[33] = 1024'b0; 
      lut4_csb_read_data_bram[34] = 1024'b0; 
      lut4_csb_read_data_bram[35] = 1024'b0; 

      lut4_msb_read_data_bram[0]  = lut4_msb_000[lut4_msb_addr_reg[ 0][4:0]];
      lut4_msb_read_data_bram[1]  = lut4_msb_001[lut4_msb_addr_reg[ 1][4:0]];
      lut4_msb_read_data_bram[2]  = lut4_msb_002[lut4_msb_addr_reg[ 2][4:0]];
      lut4_msb_read_data_bram[3]  = lut4_msb_003[lut4_msb_addr_reg[ 3][4:0]];
      lut4_msb_read_data_bram[4]  = lut4_msb_004[lut4_msb_addr_reg[ 4][4:0]];
      lut4_msb_read_data_bram[5]  = lut4_msb_005[lut4_msb_addr_reg[ 5][4:0]];
      lut4_msb_read_data_bram[6]  = lut4_msb_006[lut4_msb_addr_reg[ 6][4:0]];
      lut4_msb_read_data_bram[7]  = lut4_msb_007[lut4_msb_addr_reg[ 7][4:0]];
      lut4_msb_read_data_bram[8]  = lut4_msb_008[lut4_msb_addr_reg[ 8][4:0]];
      lut4_msb_read_data_bram[9]  = lut4_msb_009[lut4_msb_addr_reg[ 9][4:0]];
      lut4_msb_read_data_bram[10] = lut4_msb_010[lut4_msb_addr_reg[10][4:0]];
      lut4_msb_read_data_bram[11] = lut4_msb_011[lut4_msb_addr_reg[11][4:0]];
      lut4_msb_read_data_bram[12] = lut4_msb_012[lut4_msb_addr_reg[12][4:0]];
      lut4_msb_read_data_bram[13] = lut4_msb_013[lut4_msb_addr_reg[13][4:0]];
      lut4_msb_read_data_bram[14] = lut4_msb_014[lut4_msb_addr_reg[14][4:0]];
      lut4_msb_read_data_bram[15] = lut4_msb_015[lut4_msb_addr_reg[15][4:0]];
      lut4_msb_read_data_bram[16] = 1024'b0;
      lut4_msb_read_data_bram[17] = 1024'b0;
      lut4_msb_read_data_bram[18] = 1024'b0;
      lut4_msb_read_data_bram[19] = 1024'b0;
      lut4_msb_read_data_bram[20] = 1024'b0;
      lut4_msb_read_data_bram[21] = 1024'b0;
      lut4_msb_read_data_bram[22] = 1024'b0;
      lut4_msb_read_data_bram[23] = 1024'b0;
      lut4_msb_read_data_bram[24] = 1024'b0;
      lut4_msb_read_data_bram[25] = 1024'b0;
      lut4_msb_read_data_bram[26] = 1024'b0;
      lut4_msb_read_data_bram[27] = 1024'b0;
      lut4_msb_read_data_bram[28] = 1024'b0;
      lut4_msb_read_data_bram[29] = 1024'b0;
      lut4_msb_read_data_bram[30] = 1024'b0;
      lut4_msb_read_data_bram[31] = 1024'b0;
      lut4_msb_read_data_bram[32] = 1024'b0; 
      lut4_msb_read_data_bram[33] = 1024'b0; 
      lut4_msb_read_data_bram[34] = 1024'b0; 
      lut4_msb_read_data_bram[35] = 1024'b0; 

      lut5_lsb_read_data_bram[0]  = 1024'b0;
      lut5_lsb_read_data_bram[1]  = 1024'b0;
      lut5_lsb_read_data_bram[2]  = 1024'b0;
      lut5_lsb_read_data_bram[3]  = 1024'b0;
      lut5_lsb_read_data_bram[4]  = 1024'b0;
      lut5_lsb_read_data_bram[5]  = 1024'b0;
      lut5_lsb_read_data_bram[6]  = 1024'b0;
      lut5_lsb_read_data_bram[7]  = 1024'b0;
      lut5_lsb_read_data_bram[8]  = 1024'b0;
      lut5_lsb_read_data_bram[9]  = 1024'b0;
      lut5_lsb_read_data_bram[10] = 1024'b0;
      lut5_lsb_read_data_bram[11] = 1024'b0;
      lut5_lsb_read_data_bram[12] = 1024'b0;
      lut5_lsb_read_data_bram[13] = 1024'b0;
      lut5_lsb_read_data_bram[14] = 1024'b0;
      lut5_lsb_read_data_bram[15] = 1024'b0;
      lut5_lsb_read_data_bram[16] = lut5_lsb_016[lut5_lsb_addr_reg[16][7:0]];
      lut5_lsb_read_data_bram[17] = lut5_lsb_017[lut5_lsb_addr_reg[17][7:0]];
      lut5_lsb_read_data_bram[18] = lut5_lsb_018[lut5_lsb_addr_reg[18][7:0]];
      lut5_lsb_read_data_bram[19] = lut5_lsb_019[lut5_lsb_addr_reg[19][7:0]];
      lut5_lsb_read_data_bram[20] = lut5_lsb_020[lut5_lsb_addr_reg[20][7:0]];
      lut5_lsb_read_data_bram[21] = lut5_lsb_021[lut5_lsb_addr_reg[21][7:0]];
      lut5_lsb_read_data_bram[22] = lut5_lsb_022[lut5_lsb_addr_reg[22][7:0]];
      lut5_lsb_read_data_bram[23] = lut5_lsb_023[lut5_lsb_addr_reg[23][7:0]];
      lut5_lsb_read_data_bram[24] = lut5_lsb_024[lut5_lsb_addr_reg[24][7:0]];
      lut5_lsb_read_data_bram[25] = lut5_lsb_025[lut5_lsb_addr_reg[25][7:0]];
      lut5_lsb_read_data_bram[26] = lut5_lsb_026[lut5_lsb_addr_reg[26][7:0]];
      lut5_lsb_read_data_bram[27] = lut5_lsb_027[lut5_lsb_addr_reg[27][7:0]];
      lut5_lsb_read_data_bram[28] = lut5_lsb_028[lut5_lsb_addr_reg[28][7:0]];
      lut5_lsb_read_data_bram[29] = lut5_lsb_029[lut5_lsb_addr_reg[29][7:0]];
      lut5_lsb_read_data_bram[30] = lut5_lsb_030[lut5_lsb_addr_reg[30][7:0]];
      lut5_lsb_read_data_bram[31] = lut5_lsb_031[lut5_lsb_addr_reg[31][7:0]];
      lut5_lsb_read_data_bram[32] = 1024'b0;
      lut5_lsb_read_data_bram[33] = 1024'b0;
      lut5_lsb_read_data_bram[34] = 1024'b0;
      lut5_lsb_read_data_bram[35] = 1024'b0;

      lut5_msb_read_data_bram[0]  = 1024'b0;
      lut5_msb_read_data_bram[1]  = 1024'b0;
      lut5_msb_read_data_bram[2]  = 1024'b0;
      lut5_msb_read_data_bram[3]  = 1024'b0;
      lut5_msb_read_data_bram[4]  = 1024'b0;
      lut5_msb_read_data_bram[5]  = 1024'b0;
      lut5_msb_read_data_bram[6]  = 1024'b0;
      lut5_msb_read_data_bram[7]  = 1024'b0;
      lut5_msb_read_data_bram[8]  = 1024'b0;
      lut5_msb_read_data_bram[9]  = 1024'b0;
      lut5_msb_read_data_bram[10] = 1024'b0;
      lut5_msb_read_data_bram[11] = 1024'b0;
      lut5_msb_read_data_bram[12] = 1024'b0;
      lut5_msb_read_data_bram[13] = 1024'b0;
      lut5_msb_read_data_bram[14] = 1024'b0;
      lut5_msb_read_data_bram[15] = 1024'b0;
      lut5_msb_read_data_bram[16] = lut5_msb_016[lut5_msb_addr_reg[16][8:0]];
      lut5_msb_read_data_bram[17] = lut5_msb_017[lut5_msb_addr_reg[17][8:0]];
      lut5_msb_read_data_bram[18] = lut5_msb_018[lut5_msb_addr_reg[18][8:0]];
      lut5_msb_read_data_bram[19] = lut5_msb_019[lut5_msb_addr_reg[19][8:0]];
      lut5_msb_read_data_bram[20] = lut5_msb_020[lut5_msb_addr_reg[20][8:0]];
      lut5_msb_read_data_bram[21] = lut5_msb_021[lut5_msb_addr_reg[21][8:0]];
      lut5_msb_read_data_bram[22] = lut5_msb_022[lut5_msb_addr_reg[22][8:0]];
      lut5_msb_read_data_bram[23] = lut5_msb_023[lut5_msb_addr_reg[23][8:0]];
      lut5_msb_read_data_bram[24] = lut5_msb_024[lut5_msb_addr_reg[24][8:0]];
      lut5_msb_read_data_bram[25] = lut5_msb_025[lut5_msb_addr_reg[25][8:0]];
      lut5_msb_read_data_bram[26] = lut5_msb_026[lut5_msb_addr_reg[26][8:0]];
      lut5_msb_read_data_bram[27] = lut5_msb_027[lut5_msb_addr_reg[27][8:0]];
      lut5_msb_read_data_bram[28] = lut5_msb_028[lut5_msb_addr_reg[28][8:0]];
      lut5_msb_read_data_bram[29] = lut5_msb_029[lut5_msb_addr_reg[29][8:0]];
      lut5_msb_read_data_bram[30] = lut5_msb_030[lut5_msb_addr_reg[30][8:0]];
      lut5_msb_read_data_bram[31] = lut5_msb_031[lut5_msb_addr_reg[31][8:0]];
      lut5_msb_read_data_bram[32] = 1024'b0;
      lut5_msb_read_data_bram[33] = 1024'b0;
      lut5_msb_read_data_bram[34] = 1024'b0;
      lut5_msb_read_data_bram[35] = 1024'b0;

      lut76_lsb_read_data_bram[0]  = lut76_lsb_000[lut76_lsb_addr_reg[ 0][7:0]];
      lut76_lsb_read_data_bram[1]  = lut76_lsb_001[lut76_lsb_addr_reg[ 1][7:0]];
      lut76_lsb_read_data_bram[2]  = lut76_lsb_002[lut76_lsb_addr_reg[ 2][7:0]];
      lut76_lsb_read_data_bram[3]  = lut76_lsb_003[lut76_lsb_addr_reg[ 3][7:0]];
      lut76_lsb_read_data_bram[4]  = lut76_lsb_004[lut76_lsb_addr_reg[ 4][7:0]];
      lut76_lsb_read_data_bram[5]  = lut76_lsb_005[lut76_lsb_addr_reg[ 5][7:0]];
      lut76_lsb_read_data_bram[6]  = lut76_lsb_006[lut76_lsb_addr_reg[ 6][7:0]];
      lut76_lsb_read_data_bram[7]  = lut76_lsb_007[lut76_lsb_addr_reg[ 7][7:0]];
      lut76_lsb_read_data_bram[8]  = lut76_lsb_008[lut76_lsb_addr_reg[ 8][7:0]];
      lut76_lsb_read_data_bram[9]  = lut76_lsb_009[lut76_lsb_addr_reg[ 9][7:0]];
      lut76_lsb_read_data_bram[10] = lut76_lsb_010[lut76_lsb_addr_reg[10][7:0]];
      lut76_lsb_read_data_bram[11] = lut76_lsb_011[lut76_lsb_addr_reg[11][7:0]];
      lut76_lsb_read_data_bram[12] = lut76_lsb_012[lut76_lsb_addr_reg[12][7:0]];
      lut76_lsb_read_data_bram[13] = lut76_lsb_013[lut76_lsb_addr_reg[13][7:0]];
      lut76_lsb_read_data_bram[14] = lut76_lsb_014[lut76_lsb_addr_reg[14][7:0]];
      lut76_lsb_read_data_bram[15] = lut76_lsb_015[lut76_lsb_addr_reg[15][7:0]];
      lut76_lsb_read_data_bram[16] = lut76_lsb_016[lut76_lsb_addr_reg[16][7:0]];
      lut76_lsb_read_data_bram[17] = lut76_lsb_017[lut76_lsb_addr_reg[17][7:0]];
      lut76_lsb_read_data_bram[18] = lut76_lsb_018[lut76_lsb_addr_reg[18][7:0]];
      lut76_lsb_read_data_bram[19] = lut76_lsb_019[lut76_lsb_addr_reg[19][7:0]];
      lut76_lsb_read_data_bram[20] = lut76_lsb_020[lut76_lsb_addr_reg[20][7:0]];
      lut76_lsb_read_data_bram[21] = lut76_lsb_021[lut76_lsb_addr_reg[21][7:0]];
      lut76_lsb_read_data_bram[22] = lut76_lsb_022[lut76_lsb_addr_reg[22][7:0]];
      lut76_lsb_read_data_bram[23] = lut76_lsb_023[lut76_lsb_addr_reg[23][7:0]];
      lut76_lsb_read_data_bram[24] = lut76_lsb_024[lut76_lsb_addr_reg[24][7:0]];
      lut76_lsb_read_data_bram[25] = lut76_lsb_025[lut76_lsb_addr_reg[25][7:0]];
      lut76_lsb_read_data_bram[26] = lut76_lsb_026[lut76_lsb_addr_reg[26][7:0]];
      lut76_lsb_read_data_bram[27] = lut76_lsb_027[lut76_lsb_addr_reg[27][7:0]];
      lut76_lsb_read_data_bram[28] = lut76_lsb_028[lut76_lsb_addr_reg[28][7:0]];
      lut76_lsb_read_data_bram[29] = lut76_lsb_029[lut76_lsb_addr_reg[29][7:0]];
      lut76_lsb_read_data_bram[30] = lut76_lsb_030[lut76_lsb_addr_reg[30][7:0]];
      lut76_lsb_read_data_bram[31] = lut76_lsb_031[lut76_lsb_addr_reg[31][7:0]];
      lut76_lsb_read_data_bram[32] = lut76_lsb_032[lut76_lsb_addr_reg[32][7:0]];
      lut76_lsb_read_data_bram[33] = lut76_lsb_033[lut76_lsb_addr_reg[33][7:0]];
      lut76_lsb_read_data_bram[34] = lut76_lsb_034[lut76_lsb_addr_reg[34][7:0]];
      lut76_lsb_read_data_bram[35] = lut76_lsb_035[lut76_lsb_addr_reg[35][7:0]];

      lut76_msb_read_data_bram[0]  = lut76_msb_000[lut76_msb_addr_reg[ 0][8:0]];
      lut76_msb_read_data_bram[1]  = lut76_msb_001[lut76_msb_addr_reg[ 1][8:0]];
      lut76_msb_read_data_bram[2]  = lut76_msb_002[lut76_msb_addr_reg[ 2][8:0]];
      lut76_msb_read_data_bram[3]  = lut76_msb_003[lut76_msb_addr_reg[ 3][8:0]];
      lut76_msb_read_data_bram[4]  = lut76_msb_004[lut76_msb_addr_reg[ 4][8:0]];
      lut76_msb_read_data_bram[5]  = lut76_msb_005[lut76_msb_addr_reg[ 5][8:0]];
      lut76_msb_read_data_bram[6]  = lut76_msb_006[lut76_msb_addr_reg[ 6][8:0]];
      lut76_msb_read_data_bram[7]  = lut76_msb_007[lut76_msb_addr_reg[ 7][8:0]];
      lut76_msb_read_data_bram[8]  = lut76_msb_008[lut76_msb_addr_reg[ 8][8:0]];
      lut76_msb_read_data_bram[9]  = lut76_msb_009[lut76_msb_addr_reg[ 9][8:0]];
      lut76_msb_read_data_bram[10] = lut76_msb_010[lut76_msb_addr_reg[10][8:0]];
      lut76_msb_read_data_bram[11] = lut76_msb_011[lut76_msb_addr_reg[11][8:0]];
      lut76_msb_read_data_bram[12] = lut76_msb_012[lut76_msb_addr_reg[12][8:0]];
      lut76_msb_read_data_bram[13] = lut76_msb_013[lut76_msb_addr_reg[13][8:0]];
      lut76_msb_read_data_bram[14] = lut76_msb_014[lut76_msb_addr_reg[14][8:0]];
      lut76_msb_read_data_bram[15] = lut76_msb_015[lut76_msb_addr_reg[15][8:0]];
      lut76_msb_read_data_bram[16] = lut76_msb_016[lut76_msb_addr_reg[16][8:0]];
      lut76_msb_read_data_bram[17] = lut76_msb_017[lut76_msb_addr_reg[17][8:0]];
      lut76_msb_read_data_bram[18] = lut76_msb_018[lut76_msb_addr_reg[18][8:0]];
      lut76_msb_read_data_bram[19] = lut76_msb_019[lut76_msb_addr_reg[19][8:0]];
      lut76_msb_read_data_bram[20] = lut76_msb_020[lut76_msb_addr_reg[20][8:0]];
      lut76_msb_read_data_bram[21] = lut76_msb_021[lut76_msb_addr_reg[21][8:0]];
      lut76_msb_read_data_bram[22] = lut76_msb_022[lut76_msb_addr_reg[22][8:0]];
      lut76_msb_read_data_bram[23] = lut76_msb_023[lut76_msb_addr_reg[23][8:0]];
      lut76_msb_read_data_bram[24] = lut76_msb_024[lut76_msb_addr_reg[24][8:0]];
      lut76_msb_read_data_bram[25] = lut76_msb_025[lut76_msb_addr_reg[25][8:0]];
      lut76_msb_read_data_bram[26] = lut76_msb_026[lut76_msb_addr_reg[26][8:0]];
      lut76_msb_read_data_bram[27] = lut76_msb_027[lut76_msb_addr_reg[27][8:0]];
      lut76_msb_read_data_bram[28] = lut76_msb_028[lut76_msb_addr_reg[28][8:0]];
      lut76_msb_read_data_bram[29] = lut76_msb_029[lut76_msb_addr_reg[29][8:0]];
      lut76_msb_read_data_bram[30] = lut76_msb_030[lut76_msb_addr_reg[30][8:0]];
      lut76_msb_read_data_bram[31] = lut76_msb_031[lut76_msb_addr_reg[31][8:0]];
      lut76_msb_read_data_bram[32] = lut76_msb_032[lut76_msb_addr_reg[32][8:0]];
      lut76_msb_read_data_bram[33] = lut76_msb_033[lut76_msb_addr_reg[33][8:0]];
      lut76_msb_read_data_bram[34] = lut76_msb_034[lut76_msb_addr_reg[34][8:0]];
      lut76_msb_read_data_bram[35] = lut76_msb_035[lut76_msb_addr_reg[35][8:0]];
   end

   // Read data out of the memories
   always_comb begin
      for (int k=0; k<NUM_BRAM; k=k+1) begin
         lut4_lsb_read_data[k] = lut4_lsb_read_data_bram[k];
         lut4_csb_read_data[k] = lut4_csb_read_data_bram[k];
         lut4_msb_read_data[k] = lut4_msb_read_data_bram[k];
         lut5_lsb_read_data[k] = lut5_lsb_read_data_bram[k];
         lut5_msb_read_data[k] = lut5_msb_read_data_bram[k];
         lut76_lsb_read_data[k] = lut76_lsb_read_data_bram[k];
         lut76_msb_read_data[k] = lut76_msb_read_data_bram[k];
      end      
   end

   always_comb begin
      // default all outputs 
      for (int k=0; k<LUT_NUM_ELEMENTS; k=k+1) begin
         for (int l=0; l<NUM_ELEMENTS; l=l+1) begin
            lut4_lsb_output[l][k] = '0;
            lut4_csb_output[l][k] = '0;
            lut4_msb_output[l][k] = '0;
            lut5_lsb_output[l][k] = '0;
            lut5_msb_output[l][k] = '0;
            lut76_lsb_output[l][k] = '0;
            lut76_msb_output[l][k] = '0;
         end
      end

      for (int k=0; k<LUT_NUM_ELEMENTS; k=k+1) begin
         // LUT4      
         lut4_csb_output[0][k][16:0] = { 1'b0, lut4_csb_read_data[k][9:0], 6'b000000};
         for (int l=1; l<64; l=l+1) begin
            lut4_csb_output[l][k][16:0] = { 1'b0, lut4_csb_read_data[k][(l*WORD_LEN)-6 +: WORD_LEN] };
         end
         lut4_csb_output[64][k][16:0] = {11'b0, lut4_csb_read_data[k][1023:1018] };

         lut4_msb_output[0][k][16:0] = {1'b0, lut4_msb_read_data[k][3:0], 12'b000000};
         for (int l=1; l<64; l=l+1) begin
            lut4_msb_output[l][k][16:0] = {1'b0, lut4_msb_read_data[k][(l*WORD_LEN)-12 +: WORD_LEN] };
         end
         lut4_msb_output[64][k][16:0] = {5'b0, lut4_msb_read_data[k][1023:1012]};
             
         for (int l=0; l<64; l=l+1) begin
            lut4_lsb_output[l][k][16:0] = {1'b0, lut4_lsb_read_data[k][(l*WORD_LEN)-0 +: WORD_LEN]};
         end   

         // LUT5
         lut5_msb_output[0][k][16:0] = {1'b0, lut5_msb_read_data[k][7:0], 8'b00000000};
         for (int l=1; l<64; l=l+1) begin
            lut5_msb_output[l][k][16:0] = {1'b0, lut5_msb_read_data[k][(l*WORD_LEN)-8 +: WORD_LEN] };
         end
         lut5_msb_output[64][k][16:0] = {7'b0, lut5_msb_read_data[k][1023:1016]};
            
         for (int l=0; l<64; l=l+1) begin
            lut5_lsb_output[l][k][16:0] = {1'b0, lut5_lsb_read_data[k][(l*WORD_LEN)-0 +: WORD_LEN]};
         end   

         // LUT76
         lut76_msb_output[0][k][16:0] = {1'b0, lut76_msb_read_data[k][7:0], 8'b00000000};
         for (int l=1; l<64; l=l+1) begin
            lut76_msb_output[l][k][16:0] = {1'b0, lut76_msb_read_data[k][(l*WORD_LEN)-8 +: WORD_LEN] };
         end
         lut76_msb_output[64][k][16:0] = {7'b0, lut76_msb_read_data[k][1023:1016]};
            
         for (int l=0; l<64; l=l+1) begin
            lut76_lsb_output[l][k][16:0] = {1'b0, lut76_lsb_read_data[k][(l*WORD_LEN)-0 +: WORD_LEN]};
         end   
      end
   end

   // Need above loops in combo block for Verilator to process
   always_comb begin
      lut4_lsb_data  = lut4_lsb_output;
      lut4_csb_data  = lut4_csb_output;
      lut4_msb_data  = lut4_msb_output;
      lut5_lsb_data  = lut5_lsb_output;
      lut5_msb_data  = lut5_msb_output;
      lut76_lsb_data  = lut76_lsb_output;
      lut76_msb_data  = lut76_msb_output;
   end
endmodule

