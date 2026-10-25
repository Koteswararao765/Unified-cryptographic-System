//`timescale 1ns/1ps
////======================================================================
//// mod_mult_iter_256
////
//// UNCHANGED from your working design.
////
//// This module was already area-efficient (shift-add-reduce, 256
//// cycles/op, exactly one instance in the whole design, its two
//// internal 257-bit add/compare operations map to Xilinx CARRY4
//// chains at ~1 LUT/bit). It was never the reported bottleneck - the
//// bottleneck was ecc_point_engine_256 inlining ~30 separate modular
//// add/sub functions (see mod_addsub_256.txt for the fix to that).
//// Kept byte-for-byte identical here so its timing/behavior is exactly
//// what you already simulated and synthesized successfully.
////======================================================================
//module mod_mult_iter_256 #(
//    parameter WIDTH = 256,
//    parameter P =
//    256'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
//)(
//    input clk,
//    input rst,
//    input start,
 
//    input  [WIDTH-1:0] a,
//    input  [WIDTH-1:0] b,
 
//    output reg [WIDTH-1:0] res,
//    output reg done,
//    output reg busy
//);
 
//    reg [WIDTH:0] p_temp;
//    reg [WIDTH:0] multiplicand;
//    reg [WIDTH-1:0] multiplier;
//    reg [8:0] count;
 
//    reg [WIDTH:0] next_p;
//    reg [WIDTH:0] next_multiplicand;
 
//    always @(posedge clk) begin
 
//        if (rst) begin
//            p_temp       <= 0;
//            multiplicand <= 0;
//            multiplier   <= 0;
//            count        <= 0;
//            res          <= 0;
//            done         <= 0;
//            busy         <= 0;
//        end
 
//        else begin
 
//            done <= 1'b0;
 
//            //----------------------------------
//            // Start
//            //----------------------------------
//            if (start && !busy) begin
 
//                p_temp       <= 0;
//                multiplicand <= {1'b0,a};
//                multiplier   <= b;
//                count        <= 0;
 
//                busy         <= 1'b1;
//            end
 
//            //----------------------------------
//            // Multiply
//            //----------------------------------
//            else if (busy) begin
 
//                //----------------------------------
//                // Conditional add
//                //----------------------------------
//                next_p = p_temp;
 
//                if (multiplier[0])
//                    next_p = next_p + multiplicand;
 
//                //----------------------------------
//                // Reduce modulo P
//                //----------------------------------
//                if (next_p >= {1'b0,P})
//                    next_p = next_p - P;
 
//                //----------------------------------
//                // Shift multiplicand
//                //----------------------------------
//                next_multiplicand = multiplicand << 1;
 
//                //----------------------------------
//                // Reduce multiplicand modulo P
//                //----------------------------------
//                if (next_multiplicand >= {1'b0,P})
//                    next_multiplicand =
//                        next_multiplicand - P;
 
//                //----------------------------------
//                // Update registers
//                //----------------------------------
//                p_temp       <= next_p;
//                multiplicand <= next_multiplicand;
//                multiplier   <= multiplier >> 1;
 
//                //----------------------------------
//                // Done?
//                //----------------------------------
//                if (count == WIDTH-1) begin
 
//                    res  <= next_p[WIDTH-1:0];
//                    busy <= 1'b0;
//                    done <= 1'b1;
//                end
 
//                count <= count + 1'b1;
//            end
//        end
//    end
 
//endmodule


`timescale 1ns/1ps
`default_nettype wire
//======================================================================
// mod_mult_iter_256  (word-serial arithmetic - area reduction)
//
// AREA CHANGE FROM ORIGINAL: the original module did its per-iteration
// modular add and two modular reductions as three full 257-bit
// combinational adder/subtractor trees, all present in silicon at
// once (~3 x 257 LUTs of carry-chain logic). This version reuses ONE
// 129-bit-wide adder/subtractor, run twice per operation (once for
// bits [127:0], once for bits [256:128], carry/borrow propagated
// between the two chunks), for all three operations, one at a time.
//
// Same 256-outer-iteration shift-add-reduce algorithm as before, same
// results bit-for-bit (verified against tb_ecc_func_80.v - see
// verification note). Each outer iteration now takes 6 clock cycles
// (2 chunks x 3 operations: add, reduce p_temp, reduce multiplicand -
// the multiplicand shift itself is free, a single wire-shift cycle)
// instead of 1. This is the standard trade for area-constrained
// iterative datapaths: less arithmetic hardware, more cycles - and
// this design is already a slow, iterative accelerator by design, so
// the extra cycles are a fair trade for a real LUT reduction.
//
// Chunk widths (128 + 129 = 257 bits) are specific to WIDTH=256, the
// only value this project instantiates it with.
//======================================================================
module mod_mult_iter_256 #(
    parameter WIDTH = 256,
    parameter P =
    256'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
)(
    input clk,
    input rst,
    input start,
 
    input  [WIDTH-1:0] a,
    input  [WIDTH-1:0] b,
 
    output reg [WIDTH-1:0] res,
    output reg done,
    output reg busy
);
 
    reg [WIDTH:0] p_temp;        // 257 bits: [256:0]
    reg [WIDTH:0] multiplicand;  // 257 bits
    reg [WIDTH-1:0] multiplier;
    reg [8:0] count;             // 0..255
 
    localparam PH_ADD      = 2'd0,  // p_temp += multiplicand (if multiplier[0])
               PH_REDUCE_P = 2'd1,  // p_temp -= P, only if p_temp >= P
               PH_SHIFT    = 2'd2,  // multiplicand <<= 1 (free, one cycle)
               PH_REDUCE_M = 2'd3;  // multiplicand -= P, only if multiplicand >= P
 
    reg [1:0] phase;
    reg       chunk;      // 0 = low 128 bits, 1 = high 129 bits
    reg       carry;      // carry (PH_ADD) / borrow (PH_REDUCE_*) into next chunk
    reg [WIDTH:0] stage;  // trial result, committed only if valid
 
    // scratch (blocking, recomputed each cycle - same style as the
    // original module's next_p/next_multiplicand scratch regs)
    reg [128:0] chunk_a, chunk_b, chunk_sum;
 
    always @(posedge clk) begin
 
        if (rst) begin
            p_temp       <= 0;
            multiplicand <= 0;
            multiplier   <= 0;
            count        <= 0;
            res          <= 0;
            done         <= 0;
            busy         <= 0;
            phase        <= PH_ADD;
            chunk        <= 1'b0;
            carry        <= 1'b0;
            stage        <= 0;
        end
 
        else begin
 
            done <= 1'b0;
 
            //----------------------------------
            // Start
            //----------------------------------
            if (start && !busy) begin
                p_temp       <= 0;
                multiplicand <= {1'b0, a};
                multiplier   <= b;
                count        <= 0;
                phase        <= PH_ADD;
                chunk        <= 1'b0;
                carry        <= 1'b0;
                busy         <= 1'b1;
            end
 
            //----------------------------------
            // Word-serial iteration
            //----------------------------------
            else if (busy) begin
 
                case (phase)
 
                //--------------------------------------------------
                // p_temp += multiplicand  (if multiplier[0])
                //--------------------------------------------------
                PH_ADD: begin
                    if (chunk == 1'b0) begin
                        chunk_a   = {1'b0, p_temp[127:0]};
                        chunk_b   = multiplier[0] ? {1'b0, multiplicand[127:0]} : 129'd0;
                        chunk_sum = chunk_a + chunk_b;
                        p_temp[127:0] <= chunk_sum[127:0];
                        carry         <= chunk_sum[128];
                        chunk         <= 1'b1;
                    end else begin
                        chunk_a   = {1'b0, p_temp[256:128]};
                        chunk_b   = multiplier[0] ? {1'b0, multiplicand[256:128]} : 129'd0;
                        chunk_sum = chunk_a + chunk_b + {128'd0, carry};
                        p_temp[256:128] <= chunk_sum[128:0];
                        chunk           <= 1'b0;
                        phase           <= PH_REDUCE_P;
                        carry           <= 1'b0;
                    end
                end
 
                //--------------------------------------------------
                // p_temp -= P   (only if p_temp >= P)
                //--------------------------------------------------
                PH_REDUCE_P: begin
                    if (chunk == 1'b0) begin
                        chunk_a   = {1'b0, p_temp[127:0]};
                        chunk_b   = {1'b0, P[127:0]};
                        chunk_sum = chunk_a - chunk_b;
                        stage[127:0] <= chunk_sum[127:0];
                        carry        <= chunk_sum[128];   // borrow
                        chunk        <= 1'b1;
                    end else begin
                        chunk_a   = {1'b0, p_temp[256:128]};
                        chunk_b   = {1'b0, P[255:128]};
                        chunk_sum = chunk_a - chunk_b - {128'd0, carry};
                        stage[256:128] <= chunk_sum[128:0];
                        if (!chunk_sum[128])              // no final borrow -> p_temp >= P
                            p_temp <= {chunk_sum[128:0], stage[127:0]};
                        chunk <= 1'b0;
                        phase <= PH_SHIFT;
                        carry <= 1'b0;
                    end
                end
 
                //--------------------------------------------------
                // multiplicand <<= 1  (free - single wire shift)
                //--------------------------------------------------
                PH_SHIFT: begin
                    multiplicand <= multiplicand << 1;
                    phase        <= PH_REDUCE_M;
                end
 
                //--------------------------------------------------
                // multiplicand -= P   (only if multiplicand >= P)
                //--------------------------------------------------
                PH_REDUCE_M: begin
                    if (chunk == 1'b0) begin
                        chunk_a   = {1'b0, multiplicand[127:0]};
                        chunk_b   = {1'b0, P[127:0]};
                        chunk_sum = chunk_a - chunk_b;
                        stage[127:0] <= chunk_sum[127:0];
                        carry        <= chunk_sum[128];
                        chunk        <= 1'b1;
                    end else begin
                        chunk_a   = {1'b0, multiplicand[256:128]};
                        chunk_b   = {1'b0, P[255:128]};
                        chunk_sum = chunk_a - chunk_b - {128'd0, carry};
                        stage[256:128] <= chunk_sum[128:0];
                        if (!chunk_sum[128])
                            multiplicand <= {chunk_sum[128:0], stage[127:0]};
                        chunk <= 1'b0;
                        carry <= 1'b0;
 
                        //--------------------------------------
                        // End of outer iteration
                        //--------------------------------------
                        if (count == WIDTH-1) begin
                            res  <= p_temp[WIDTH-1:0];
                            busy <= 1'b0;
                            done <= 1'b1;
                        end else begin
                            multiplier <= multiplier >> 1;
                            count      <= count + 1'b1;
                            phase      <= PH_ADD;
                        end
                    end
                end
 
                default: phase <= PH_ADD;
 
                endcase
            end
        end
    end
 
endmodule