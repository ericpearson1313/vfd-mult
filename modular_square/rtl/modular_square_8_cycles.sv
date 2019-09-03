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
   localparam int EXTRA_MUL_TREE_BITS = 11;  // 10 for CSA and 1 for 2x AB terms
   localparam int MUL_BIT_LEN         = ( ((BIT_LEN*2) - WORD_LEN) + EXTRA_MUL_TREE_BITS ); // 29b
   localparam int GRID_BIT_LEN        =  MUL_BIT_LEN; // 29b
   localparam int GRID_SIZE           = ( MUL_NUM_ELEMENTS*2 ); // 132 elements in a 2K word
   localparam int LOOK_UP_WIDTH       = ( int'(WORD_LEN / 2) ); // 8b Luts (also support 9 bits)

   localparam int ACC_ELEMENTS        = 36;  // 36 luts 
   localparam int ACC_EXTRA_ELEMENTS  = 1; // Addin the lower bits of the product
   localparam int ACC_EXTRA_BIT_LEN   = 12; // WAS: $clog2(ACC_ELEMENTS+ACC_EXTRA_ELEMENTS);
   localparam int ACC_BIT_LEN         = ( BIT_LEN + ACC_EXTRA_BIT_LEN ); // 29b

   localparam int IDLE                = 0,
                  CYCLE_0             = 1,
                  CYCLE_1             = 2,
                  CYCLE_2             = 3,
                  CYCLE_3             = 4,
                  NUM_CYCLES          = 5;

   // Flop incoming data from external source
   logic [BIT_LEN-1:0]       sq_in_d1[NUM_ELEMENTS];  // 66 x 17b
   logic                     start_d1;

   // Input to square (start of phase 1)
   logic [BIT_LEN-1:0]       curr_sq_in[NUM_ELEMENTS]; // 66 x 17b

   // Cycle number state machine
   logic [NUM_CYCLES-1:0]    next_cycle; // 4 cycles
   logic [NUM_CYCLES-1:0]    curr_cycle; // 4 cycles

   // Multiplier selects in/out and values
   logic [MUL_BIT_LEN-1:0]   mul_c[ GRID_SIZE ]; // 132 x 29b
   logic [MUL_BIT_LEN-1:0]   mul_s[ GRID_SIZE ]; // 132 x 29b

   logic [GRID_BIT_LEN:0]    grid_sum[GRID_SIZE]; // 132 x 30b 
   logic [BIT_LEN-1:0]       reduced_grid_sum[GRID_SIZE]; // 132 x 17b
   reg   [BIT_LEN-1:0]       reduced_grid_reg[GRID_SIZE]; // 132 x 17b

   logic [LOOK_UP_WIDTH:0]   lut_addr0[ACC_ELEMENTS]; // 32 x 9b -- LBS8 of lower V54 words
   logic [LOOK_UP_WIDTH:0]   lut_addr1[ACC_ELEMENTS]; // 32 x 9b -- MSB9 of lower V54 words
   logic [LOOK_UP_WIDTH:0]   lut_addr2[ACC_ELEMENTS]; // 36 x 9b -- LSB8 of Upper V76 words
   logic [LOOK_UP_WIDTH:0]   lut_addr3[ACC_ELEMENTS]; // 36 x 9b -- MSB9 of upper V76 words
   wire  [BIT_LEN-1:0]       lut_data0[NUM_ELEMENTS][ACC_ELEMENTS]; // 66 words (of 36 luts) of 17b
   wire  [BIT_LEN-1:0]       lut_data1_d[NUM_ELEMENTS][ACC_ELEMENTS];
   reg   [BIT_LEN-1:0]       lut_data1[NUM_ELEMENTS][ACC_ELEMENTS];
   wire  [BIT_LEN-1:0]       lut_data2[NUM_ELEMENTS][ACC_ELEMENTS];
   wire  [BIT_LEN-1:0]       lut_data3_d[NUM_ELEMENTS][ACC_ELEMENTS];
   reg   [BIT_LEN-1:0]       lut_data3[NUM_ELEMENTS][ACC_ELEMENTS];

   logic [ACC_BIT_LEN-1:0]   acc_stack[NUM_ELEMENTS][SEGMENT_ELEMENTS+2*ACC_ELEMENTS+ACC_EXTRA_ELEMENTS]; // 66 sumation columns, each of 137=64+72+1 of 29b
   logic [ACC_BIT_LEN-1:0]   acc_C[NUM_ELEMENTS]; // 66 words of 17+12=29b
   logic [ACC_BIT_LEN-1:0]   acc_S[NUM_ELEMENTS];

   logic [ACC_BIT_LEN:0]     acc_sum[NUM_ELEMENTS]; // 66 column sums of 30 bits
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
                  next_cycle[CYCLE_0]      = 1'b1;
               end
               else begin
                  next_cycle[IDLE]         = 1'b1;
               end
            end
            curr_cycle[CYCLE_0] : begin next_cycle[CYCLE_1] = 1'b1; end
            curr_cycle[CYCLE_1] : begin next_cycle[CYCLE_2] = 1'b1; end
            curr_cycle[CYCLE_2] : begin next_cycle[CYCLE_3] = 1'b1; end
            curr_cycle[CYCLE_3] : begin next_cycle[CYCLE_0] = 1'b1; out_valid = 1; end
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

   square #(.NUM_ELEMENTS( 66 ),
              .BIT_LEN(    17 ),
              .WORD_LEN(   16 )
             )
      square_ (
                .clk(clk),
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
   dual_reduction_lut reduction_lut_ (
                     .clk(clk), // Luts must be clocked
                     .lut54_addr( ( curr_cycle[CYCLE_1] ) ? lut_addr1 : lut_addr0 ),
                     .lut76_addr( ( curr_cycle[CYCLE_1] ) ? lut_addr3 : lut_addr2 ),
                     .lut54_lsb_data( lut_data0 ),
                     .lut76_lsb_data( lut_data2 ),
                     .lut54_msb_data( lut_data1_d ),
                     .lut76_msb_data( lut_data3_d )
                     
                    );

   // Accumulate reduction lut values with running total
   always_ff @(posedge clk) begin
      if ( curr_cycle[CYCLE_2] ) begin
        lut_data1 <= lut_data1_d;
        lut_data3 <= lut_data3_d;
      end
   end
   
   always_comb begin
      for (int k=0; k<NUM_ELEMENTS; k=k+1) begin
         for (int j=0; j<ACC_ELEMENTS; j=j+1) begin
            if( j < SEGMENT_ELEMENTS ) begin
                // V54[32]
                acc_stack[k][j+  0][ACC_BIT_LEN-1:0] = {{ACC_EXTRA_BIT_LEN{1'b0}}, lut_data0[k][j][BIT_LEN-1:0]};
                acc_stack[k][j+ 32][ACC_BIT_LEN-1:0] = {{ACC_EXTRA_BIT_LEN{1'b0}}, lut_data1[k][j][BIT_LEN-1:0]};
                // V76[36]
                acc_stack[k][j+ 64][ACC_BIT_LEN-1:0] = {{ACC_EXTRA_BIT_LEN{1'b0}}, lut_data2[k][j][BIT_LEN-1:0]};
                acc_stack[k][j+100][ACC_BIT_LEN-1:0] = {{ACC_EXTRA_BIT_LEN{1'b0}}, lut_data3[k][j][BIT_LEN-1:0]};
            end else begin
                acc_stack[k][j+ 64][ACC_BIT_LEN-1:0] = {{ACC_EXTRA_BIT_LEN{1'b0}}, lut_data2[k][j][BIT_LEN-1:0]};
                acc_stack[k][j+100][ACC_BIT_LEN-1:0] = {{ACC_EXTRA_BIT_LEN{1'b0}}, lut_data3[k][j][BIT_LEN-1:0]};
            end
         end
         acc_stack[k][136][ACC_BIT_LEN-1:0] = {{ACC_EXTRA_BIT_LEN{1'b0}}, reduced_grid_reg[k][BIT_LEN-1:0]};
      end
   end

   // Instantiate compressor trees to accumulate over accumulator columns
   genvar i;
   
   generate
      for (i=0; i<NUM_ELEMENTS; i=i+1) begin : final_acc
         compressor_tree_3_to_2 #(.NUM_ELEMENTS( 137 ), // V54 lsb, msb, V76 lsb, msb, V30
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
      if ( curr_cycle[CYCLE_3] ) begin
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
     parameter int COL_BIT_LEN      = (MUL_OUT_BIT_LEN - WORD_LEN + 1),  // 19b (extra +1 for prod*2 operations
     parameter int EXTRA_TREE_BITS  = 10,                                //+10b to reduce 66 stages 
     parameter int OUT_BIT_LEN      = COL_BIT_LEN + EXTRA_TREE_BITS      // 29b is our per column data path width
    )
   (
    input  logic                       clk,
    input  logic [BIT_LEN-1:0]         A[NUM_ELEMENTS],      //  66 x 17b
    output logic [OUT_BIT_LEN-1:0]     C[NUM_ELEMENTS*2],    // 132 x 19b
    output logic [OUT_BIT_LEN-1:0]     S[NUM_ELEMENTS*2]     // 132 x 29b
   );

   localparam int GRID_PAD_SHORT   = EXTRA_TREE_BITS;                             // +10b padding
   localparam int GRID_PAD_LONG    = (COL_BIT_LEN - WORD_LEN) + EXTRA_TREE_BITS;  // +13b padding

   logic [MUL_OUT_BIT_LEN-1:0] mul_result[NUM_ELEMENTS*NUM_ELEMENTS];  // 66*66 = 4356 x 34b ( ~150K wires )
   logic [OUT_BIT_LEN-1:0]     grid[NUM_ELEMENTS*2][NUM_ELEMENTS*2];   // 132 rows of 132 columns x 29b ( ~500K wires! )

   // Instantiate the diagonal upper half of the multiplier array  ( only 2211 multipliers )
   genvar x, y;
   generate
      for (y=0; y<NUM_ELEMENTS; y=y+1) begin 
         for (x=y; x<NUM_ELEMENTS; x=x+1) begin // Diagonal matrix
            multiplier #(.A_BIT_LEN(BIT_LEN),
                         .B_BIT_LEN(BIT_LEN)
                        ) multiplier (
                                      .clk(clk),
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
         localparam integer CUR_ELEMENTS = (i <  NUM_ELEMENTS) ? i : NUM_ELEMENTS - int'(i/2);
         localparam integer GRID_INDEX   = (i <= NUM_ELEMENTS) ? 0 : (i == NUM_ELEMENTS) ? 1 : ((i - NUM_ELEMENTS)*2);
         logic [OUT_BIT_LEN-1:0] C_col;
         logic [OUT_BIT_LEN-1:0] S_col; 

         compressor_tree_3_to_2 #(.NUM_ELEMENTS(CUR_ELEMENTS),
                                  .BIT_LEN(OUT_BIT_LEN)
                                 )
            compressor_tree_3_to_2 (
               .terms(grid[i][GRID_INDEX:(GRID_INDEX + CUR_ELEMENTS - 1)]),
               .C(C_col),
               .S(S_col)
            );

         always_comb begin
            C[i][OUT_BIT_LEN-1:0] = C_col[OUT_BIT_LEN-1:0];
            S[i][OUT_BIT_LEN-1:0] = S_col[OUT_BIT_LEN-1:0];
         end
      end
   endgenerate
endmodule

/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

module dual_reduction_lut
   #(
     parameter int REDUNDANT_ELEMENTS    = 2,
     parameter int NONREDUNDANT_ELEMENTS = 64,
     parameter int NUM_SEGMENTS          = 1,
     parameter int WORD_LEN              = 16,
     parameter int BIT_LEN               = 17,
     parameter int DIN_LEN               = 8,

     parameter int NUM_ELEMENTS          = REDUNDANT_ELEMENTS+NONREDUNDANT_ELEMENTS,
     parameter int LOOK_UP_WIDTH         = int'(WORD_LEN / 2),
     parameter int EXTRA_ELEMENTS        = 2,
     parameter int LUT_NUM_ELEMENTS      = 36
    )
   (
    input  logic                     clk,
    input  logic [LOOK_UP_WIDTH:0]   lut54_addr[LUT_NUM_ELEMENTS], // V54 32 x lsb [7:0], or msb[16:8]
    input  logic [LOOK_UP_WIDTH:0]   lut76_addr[LUT_NUM_ELEMENTS], // V76 36 x lsb [7:0], or msb[16:8]
    output logic [BIT_LEN-1:0]       lut54_lsb_data[NUM_ELEMENTS][LUT_NUM_ELEMENTS],
    output logic [BIT_LEN-1:0]       lut76_lsb_data[NUM_ELEMENTS][LUT_NUM_ELEMENTS],
    output logic [BIT_LEN-1:0]       lut54_msb_data[NUM_ELEMENTS][LUT_NUM_ELEMENTS],
    output logic [BIT_LEN-1:0]       lut76_msb_data[NUM_ELEMENTS][LUT_NUM_ELEMENTS]
   );

   // 9 bit lookups
   localparam int NUM_LUT_ENTRIES   = 2**(LOOK_UP_WIDTH+1);
   localparam int LUT_WIDTH         = WORD_LEN * NONREDUNDANT_ELEMENTS;

   localparam int NUM_BRAM          = LUT_NUM_ELEMENTS;

   logic [LUT_WIDTH-1:0]  lut54_read_data[LUT_NUM_ELEMENTS];
   logic [LUT_WIDTH-1:0]  lut76_read_data[LUT_NUM_ELEMENTS];
   logic [LUT_WIDTH-1:0]  lut54_read_data_bram[NUM_BRAM];
   logic [LUT_WIDTH-1:0]  lut76_read_data_bram[NUM_BRAM];
   logic [BIT_LEN-1:0]    lut54_lsb_output[NUM_ELEMENTS][LUT_NUM_ELEMENTS];
   logic [BIT_LEN-1:0]    lut76_lsb_output[NUM_ELEMENTS][LUT_NUM_ELEMENTS];
   logic [BIT_LEN-1:0]    lut54_msb_output[NUM_ELEMENTS][LUT_NUM_ELEMENTS];
   logic [BIT_LEN-1:0]    lut76_msb_output[NUM_ELEMENTS][LUT_NUM_ELEMENTS];

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
            lut54_lsb_output[l][k] = '0;
            lut76_lsb_output[l][k] = '0;
            lut54_msb_output[l][k] = '0;
            lut76_msb_output[l][k] = '0;
         end
      end
      for (int k=0; k<LUT_NUM_ELEMENTS; k=k+1) begin
         for (int l=0; l<NONREDUNDANT_ELEMENTS+1; l=l+1) begin
            if (l == 0) begin
               lut54_msb_output[l][k][LOOK_UP_WIDTH-1:0] = '0;
               lut76_msb_output[l][k][LOOK_UP_WIDTH-1:0] = '0;
            end else begin
               lut54_msb_output[l][k][LOOK_UP_WIDTH-1:0] = lut54_read_data[k][((l-1)*WORD_LEN)+LOOK_UP_WIDTH+:LOOK_UP_WIDTH];
               lut76_msb_output[l][k][LOOK_UP_WIDTH-1:0] = lut76_read_data[k][((l-1)*WORD_LEN)+LOOK_UP_WIDTH+:LOOK_UP_WIDTH];
            end
            if (l < NONREDUNDANT_ELEMENTS) begin
                 lut54_lsb_output[l][k] = {{(BIT_LEN-WORD_LEN){1'b0}}, lut54_read_data[k][(l*WORD_LEN)+:WORD_LEN]};
                 lut76_lsb_output[l][k] = {{(BIT_LEN-WORD_LEN){1'b0}}, lut76_read_data[k][(l*WORD_LEN)+:WORD_LEN]};
            end
         end
      end
   end

   // Need above loops in combo block for Verilator to process
   always_comb begin
      lut54_lsb_data  = lut54_lsb_output;
      lut76_lsb_data  = lut76_lsb_output;
      lut54_msb_data  = lut54_msb_output;
      lut76_msb_data  = lut76_msb_output;
   end
endmodule

