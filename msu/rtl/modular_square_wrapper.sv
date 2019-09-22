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

// Pipe the modular squaring circuit IOs to relieve timing pressure. 
`ifndef MOD_LEN_DEF
`define MOD_LEN_DEF 1024
`endif

module modular_square_wrapper
   #(
     parameter int MOD_LEN               = `MOD_LEN_DEF,

     parameter int WORD_LEN              = 16,
     parameter int REDUNDANT_ELEMENTS    = 2,
     parameter int NONREDUNDANT_ELEMENTS = MOD_LEN / WORD_LEN,
     parameter int NUM_ELEMENTS          = REDUNDANT_ELEMENTS +
                                           NONREDUNDANT_ELEMENTS,
     // Send the coefficients out in 32 bits - somewhat inefficient use
     // of space but not timing critical and easier to read/debug
     parameter int SQ_OUT_BITS           = NUM_ELEMENTS * WORD_LEN*2
    )
   (
    input logic                    clk,
    input logic                    reset,
    input logic                    start,
    input logic [MOD_LEN-1:0]      sq_in,
    output logic [SQ_OUT_BITS-1:0] sq_out,
    output logic                   valid
   );

   localparam int BIT_LEN               = 17;
   localparam int IO_STAGES             = 3;

   logic               start_stages[IO_STAGES];
   logic [BIT_LEN-1:0] sq_in_stages[IO_STAGES][NUM_ELEMENTS];
   logic [BIT_LEN-1:0] sq_out_stages[IO_STAGES][NUM_ELEMENTS];
   logic               valid_stages[IO_STAGES];

   logic mmcm_fb;
   logic modsq_clk;
   logic rst_hold, rst_fb_cdc1, rst_fb_cdc2;
   logic modsq_rst_cdc1, modsq_rst_cdc2, modsq_rst;
   logic start_hold, start_fb_cdc1, start_fb_cdc2;
   logic modsq_start_cdc1, modsq_start_cdc2, modsq_start_q;
   logic modsq_start;

   logic modsq_valid_cdc1, modsq_valid_cdc2, modsq_valid_q;
   logic modsq_valid;
   logic modsq_valid_toggle;
      
   genvar              j;

   // Split sq_in into polynomial coefficients
   generate
      for(j = 0; j < NONREDUNDANT_ELEMENTS; j++) begin
         always @(posedge clk) begin
            sq_in_stages[0][j] <= {{(BIT_LEN-WORD_LEN){1'b0}},
                                   sq_in[j*WORD_LEN +: WORD_LEN]};
         end
      end
      // Clear the redundant coefficients
      for(j = NONREDUNDANT_ELEMENTS; j < NUM_ELEMENTS; j++) begin
         always @(posedge clk) begin
            sq_in_stages[0][j] <= 0;
         end
      end
   endgenerate

   // Gather the output coefficients into sq_out
   generate
      for(j = 0; j < NUM_ELEMENTS; j++) begin
         always_comb begin
            sq_out[j*WORD_LEN*2 +: 2*WORD_LEN] = {{(2*WORD_LEN-BIT_LEN){1'b0}},
                                                 sq_out_stages[IO_STAGES-1][j]};
         end
      end
   endgenerate

   assign valid  = valid_stages[IO_STAGES-1];

   // Create the pipeline
   generate
      for(j = 1; j < IO_STAGES; j++) begin
         always_ff @(posedge clk) begin
            sq_in_stages[j]  <= sq_in_stages[j-1];
            sq_out_stages[j] <= sq_out_stages[j-1];
            valid_stages[j]  <= valid_stages[j-1];
         end
      end
   endgenerate

   modular_square_8_cycles 
     #(
       .NONREDUNDANT_ELEMENTS(NONREDUNDANT_ELEMENTS)
       )
   modsqr(
          .clk                ( modsq_clk ),
          .reset              ( modsq_rst ),
          .start              ( modsq_start ),
          .sq_in              (sq_in_stages[IO_STAGES-1]),
          .sq_out             (sq_out_stages[0]),
          .valid              ( modsq_valid )
          );

//// Reset CDC ////
always_ff @(posedge clk) begin
    rst_hold <= reset | ( rst_hold & !rst_fb_cdc2 );
    rst_fb_cdc2 <= rst_fb_cdc1;
    rst_fb_cdc1 <= modsq_rst_cdc2;
end
always_ff @(posedge modsq_clk) begin
    modsq_rst_cdc1 <= rst_hold;
    modsq_rst_cdc2 <= modsq_rst_cdc1;
end
assign modsq_rst = modsq_rst_cdc2;

///// Start CDC ////
always_ff @(posedge clk) begin
    start_hold <= reset | ( start_hold & !start_fb_cdc2 );
    start_fb_cdc2 <= start_fb_cdc1;
    start_fb_cdc1 <= modsq_start_cdc2;
end
always_ff @(posedge modsq_clk) begin
    modsq_start_cdc1 <= start_hold;
    modsq_start_cdc2 <= modsq_start_cdc1;
    modsq_start_q <= modsq_start_cdc2;
end
assign modsq_start = !modsq_start_q & modsq_start_cdc2;

///// Valid CDC //////
always_ff @(posedge modsq_clk ) begin
    modsq_valid_toggle <= modsq_valid_toggle ^ modsq_valid;
end
always_ff @(posedge clk) begin
    modsq_valid_cdc1 <= modsq_valid_toggle;
    modsq_valid_cdc2 <= modsq_valid_cdc1;
    modsq_valid_q    <= modsq_valid_cdc2;
end
assign valid = modsq_valid_q ^ modsq_valid_cdc2;

///// PLL /////////

MMCME4_BASE #(
       .CLKIN1_PERIOD    ( 8.000  ), 
       .DIVCLK_DIVIDE    ( 1      ),   
       .CLKFBOUT_MULT_F  ( 12.75  ),
       .CLKOUT0_DIVIDE_F ( 12.675 ),
       .CLKOUT1_DIVIDE   ( 20     ),
       .CLKOUT2_DIVIDE   ( 20     ),
       .CLKOUT3_DIVIDE   ( 20     ),
       .CLKOUT4_DIVIDE   ( 20     ),
       .CLKOUT5_DIVIDE   ( 20     ),
       .CLKOUT6_DIVIDE   ( 20     ),
       .CLKOUT0_DUTY_CYCLE(0.5),   
       .CLKOUT1_DUTY_CYCLE(0.5),   
       .CLKOUT2_DUTY_CYCLE(0.5),   
       .CLKOUT3_DUTY_CYCLE(0.5),   
       .CLKOUT4_DUTY_CYCLE(0.5),   
       .CLKOUT5_DUTY_CYCLE(0.5),   
       .CLKOUT6_DUTY_CYCLE(0.5),   
       .CLKFBOUT_PHASE(0.0),       
       .CLKOUT0_PHASE(0.0),        
       .CLKOUT1_PHASE(0.0),        
       .CLKOUT2_PHASE(0.0),        
       .CLKOUT3_PHASE(0.0),        
       .CLKOUT4_PHASE(0.0),        
       .CLKOUT5_PHASE(0.0),        
       .CLKOUT6_PHASE(0.0),        
       .BANDWIDTH("OPTIMIZED"),   
       .CLKOUT4_CASCADE("FALSE"),  
       .IS_CLKFBIN_INVERTED(1'b0), 
       .IS_CLKIN1_INVERTED(1'b0),  
       .IS_PWRDWN_INVERTED(1'b0),  
       .IS_RST_INVERTED(1'b0),     
       .REF_JITTER1(0.010),        
       .STARTUP_WAIT("FALSE")       
    )
 MMCME4_inst_ (
       .CLKIN1   ( clk       ),                 
       .CLKFBIN  ( mmcm_fb   ),        
       .CLKFBOUT ( mmcm_fb   ),            
       .CLKOUT0  ( modsq_clk ),     
       .CLKOUT1  ( ),     
       .CLKOUT2  ( ),     
       .CLKOUT3  ( ),     
       .CLKOUT4  ( ),  
       .CLKOUT5  ( ),            
       .CLKOUT6  ( ),  
       .CLKFBOUTB( ),                     
       .CLKOUT0B ( ),                      
       .CLKOUT1B ( ),                      
       .CLKOUT2B ( ),                      
       .CLKOUT3B ( ),
       .LOCKED   (   ),                        
       .PWRDWN   ( 1'b0 ),                    
       .RST      ( 1'b0 )          
    );

endmodule
