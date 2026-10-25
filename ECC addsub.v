//`timescale 1ns/1ps
////======================================================================
//// mod_addsub_256
////
//// NEW MODULE - the single, shared modular add/subtract unit for the
//// whole ECC engine.
////
//// WHY THIS EXISTS:
////   In the previous ecc_point_engine_256 (add.v), mod_add / mod_sub /
////   mod_dbl were Verilog *functions*. Functions are inlined at every
////   call site - they are NOT automatically merged into one piece of
////   hardware by Vivado. With ~30 call sites across the doubling flow
////   and the addition flow, the design was building ~30 separate
////   256-bit adder/subtractor/comparator instances. That inline
////   duplication (not the multiplier, which was already a single
////   instance) is the main reason U_ENG alone synthesized to 21,604
////   LUTs against the xc7a35t's 20,800-LUT budget.
////
////   This module is instantiated EXACTLY ONCE inside
////   ecc_point_engine_256. Every modular add/sub anywhere in the
////   doubling flow or the addition flow is rerouted through this one
////   instance via registered inputs (2-cycle dispatch/capture, the
////   same pattern already used for the shared multiplier). That turns
////   ~30 duplicated adder/subtractors into exactly one, which is the
////   single biggest resource-sharing change in this rewrite.
////
//// HOW IT WORKS:
////   sub = 0 : res = (x + y) mod P
////   sub = 1 : res = (x - y) mod P computed as (x + P - y) mod P, which
////             is always non-negative in (WIDTH+1)-bit unsigned math
////             since 0 <= x,y < P, so no separate "is x < y" comparator
////             is needed - just the one final "subtract P if >= P"
////             correction shared by both directions.
////
////   Purely combinational: 0 extra pipeline stage, only "res" changes
////   whenever x/y/sub change on the same clock edge - engine states
////   register x/y/sub in one cycle and read res in the next.
////======================================================================
//module mod_addsub_256 #(
//    parameter WIDTH = 256,
//    parameter P =
//    256'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
//)(
//    input      [WIDTH-1:0] x,
//    input      [WIDTH-1:0] y,
//    input                  sub,      // 0 = add, 1 = subtract
//    output     [WIDTH-1:0] res
//);
 
//    wire [WIDTH:0] xe = {1'b0, x};
//    wire [WIDTH:0] ye = {1'b0, y};
//    wire [WIDTH:0] pe = {1'b0, P};
 
//    // add branch : x + y            (range [0 , 2P-2])
//    // sub branch : x + P - y        (range [1 , 2P-1], never underflows
//    //              because y < P <= x+P for all valid field elements)
//    wire [WIDTH:0] raw = sub ? (xe + pe - ye) : (xe + ye);
 
//    // single shared correction: subtract P once if the raw value has
//    // walked out of [0,P)
//    wire [WIDTH:0] corrected = raw - pe;
//    wire           need_corr = (raw >= pe);
 
//    assign res = need_corr ? corrected[WIDTH-1:0] : raw[WIDTH-1:0];
 
//endmodule
 
//`timescale 1ns/1ps
////======================================================================
//// mod_addsub_256
////
//// NEW MODULE - the single, shared modular add/subtract unit for the
//// whole ECC engine.
////
//// WHY THIS EXISTS:
////   In the previous ecc_point_engine_256 (add.v), mod_add / mod_sub /
////   mod_dbl were Verilog *functions*. Functions are inlined at every
////   call site - they are NOT automatically merged into one piece of
////   hardware by Vivado. With ~30 call sites across the doubling flow
////   and the addition flow, the design was building ~30 separate
////   256-bit adder/subtractor/comparator instances. That inline
////   duplication (not the multiplier, which was already a single
////   instance) is the main reason U_ENG alone synthesized to 21,604
////   LUTs against the xc7a35t's 20,800-LUT budget.
////
////   This module is instantiated EXACTLY ONCE inside
////   ecc_point_engine_256. Every modular add/sub anywhere in the
////   doubling flow or the addition flow is rerouted through this one
////   instance via registered inputs (2-cycle dispatch/capture, the
////   same pattern already used for the shared multiplier). That turns
////   ~30 duplicated adder/subtractors into exactly one, which is the
////   single biggest resource-sharing change in this rewrite.
////
//// HOW IT WORKS (fixed - see erratum below):
////   sub = 0 : res = (x + y) mod P
////             s = x+y  (range [0,2P-2]); if s>=P, s-=P.  2 chained
////             257-bit add/subtracts, at most.
////   sub = 1 : res = (x - y) mod P
////             mux between (x-y), used when x>=y, and (x+P-y), used
////             when x<y. These are two PARALLEL single-op candidates,
////             not a chain - and x+P-y is provably already in [0,P)
////             whenever x<y (since x+P-y = P-(y-x) and 0<y-x<P), so
////             no further correction is ever needed for the subtract
////             direction.
////
////   ERRATUM (first version of this file): an earlier version of this
////   module always computed x+P-y for sub=1 and then ran an
////   additional, unconditional "subtract P if still >= P" correction
////   on top of that. That correction is mathematically redundant (see
////   above) and, worse, it turned the sub path into 3 chained 257-bit
////   adds combinationally in a single cycle with no register between
////   them, versus the 2-chain max that the original per-call
////   mod_add/mod_sub functions used (and which met timing at
////   WNS = +6.399 ns). That 3rd chained add is what caused
////   WNS = -8.601 ns / 5381 failing endpoints once this ALU became the
////   single most-reused piece of combinational logic in the design.
////   This version is structurally identical to the original two
////   functions (same 2-op-max depth per branch), just consolidated
////   into one shared instance - so it should return to the original's
////   timing behavior while keeping the ~20:1 resource-sharing win.
////
////   Purely combinational: 0 extra pipeline stage, only "res" changes
////   whenever x/y/sub change on the same clock edge - engine states
////   register x/y/sub in one cycle and read res in the next.
////======================================================================
//module mod_addsub_256 #(
//    parameter WIDTH = 256,
//    parameter P =
//    256'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
//)(
//    input      [WIDTH-1:0] x,
//    input      [WIDTH-1:0] y,
//    input                  sub,      // 0 = add, 1 = subtract
//    output     [WIDTH-1:0] res
//);
 
//    wire [WIDTH:0] xe = {1'b0, x};
//    wire [WIDTH:0] ye = {1'b0, y};
//    wire [WIDTH:0] pe = {1'b0, P};
 
//    //------------------------------------------------------------
//    // ADD path (sub=0): exactly the original mod_add - 2 ops max
//    //------------------------------------------------------------
//    wire [WIDTH:0] add_s = xe + ye;
//    wire [WIDTH:0] add_r = (add_s >= pe) ? (add_s - pe) : add_s;
 
//    //------------------------------------------------------------
//    // SUB path (sub=1): exactly the original mod_sub - a mux between
//    // two independent single/2-op candidates, no chained correction
//    //------------------------------------------------------------
//    wire [WIDTH:0] sub_r = (x >= y) ? (xe - ye) : (xe + pe - ye);
 
//    assign res = sub ? sub_r[WIDTH-1:0] : add_r[WIDTH-1:0];
 
//endmodule


`timescale 1ns/1ps
`default_nettype wire
//======================================================================
// mod_addsub_256   (word-serial arithmetic - area reduction)
//
// AREA CHANGE FROM PREVIOUS VERSION: previously this was a purely
// combinational module - a full 257-bit add path (add + conditional
// subtract-P, two full-width adder/subtractor trees) running in
// parallel with a full 257-bit subtract path (comparator + two more
// full-width adder/subtractor trees). That is up to four ~257-bit
// carry-chain structures alive in silicon at once.
//
// This version reuses ONE 129-bit adder/subtractor, run in two
// chunks (bits [127:0] then bits [256:128], carry/borrow propagated
// between them), same idea as the word-serial multiplier
// (mod_mult_iter_256). Because that reused hardware needs several
// clock cycles now, this module is no longer purely combinational -
// it has a start/done handshake, exactly like the multiplier already
// does, and every caller in point.v was updated to dispatch-and-wait
// instead of read-immediately (verified bit-exact against the
// previous version via tb_ecc_func_80.v).
//
// Result definition (unchanged):
//   sub == 0 :  res = (x + y) mod P
//   sub == 1 :  res = (x - y) mod P        [= x>=y ? x-y : x+P-y]
//
// Latency: 2 cycles (add mode, or sub mode with no borrow) or
// 4 cycles (sub mode where x<y, needs the +P correction) or always
// 4 cycles for add mode (op + P-reduction check).
//======================================================================
module mod_addsub_256 #(
    parameter WIDTH = 256,
    parameter P =
    256'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
)(
    input clk,
    input rst,
    input start,
 
    input [WIDTH-1:0] x,
    input [WIDTH-1:0] y,
    input              sub,
 
    output reg [WIDTH-1:0] res,
    output reg             done,
    output reg             busy
);
 
    localparam PH_OP  = 1'b0,   // acc = x+y  (add mode)  or  acc = x-y (sub mode)
               PH_FIN = 1'b1;   // add mode: trial-subtract P from acc, commit if valid
                                 // sub mode (borrow case only): acc = acc + P
 
    reg           phase;
    reg           chunk;        // 0 = low 128 bits, 1 = high 129 bits
    reg           carry;        // carry/borrow propagated between chunks
    reg           mode_sub;     // latched 'sub' input for this whole operation
    reg           op_borrow;    // latched borrow-out from PH_OP (sub mode only)
    reg [WIDTH:0] acc;          // 257-bit working accumulator
    reg [WIDTH:0] stage;        // trial-subtract staging (add-mode P-reduction)
 
    // scratch (blocking, recomputed each cycle)
    reg [128:0] chunk_a, chunk_b, chunk_sum;
 
    always @(posedge clk) begin
 
        if (rst) begin
            res <= 0; done <= 0; busy <= 0;
            phase <= PH_OP; chunk <= 1'b0; carry <= 1'b0;
            mode_sub <= 1'b0; op_borrow <= 1'b0;
            acc <= 0; stage <= 0;
        end else begin
 
            done <= 1'b0;
 
            //----------------------------------
            // Start
            //----------------------------------
            if (start && !busy) begin
                busy     <= 1'b1;
                mode_sub <= sub;
                acc      <= {1'b0, x};
                phase    <= PH_OP;
                chunk    <= 1'b0;
                carry    <= 1'b0;
            end
 
            //----------------------------------
            // Word-serial iteration
            //----------------------------------
            else if (busy) begin
 
                case (phase)
 
                //--------------------------------------------------
                // acc = x + y  (add mode)  or  acc = x - y  (sub mode)
                //--------------------------------------------------
                PH_OP: begin
                    if (chunk == 1'b0) begin
                        chunk_a   = {1'b0, acc[127:0]};
                        chunk_b   = {1'b0, y[127:0]};
                        chunk_sum = mode_sub ? (chunk_a - chunk_b) : (chunk_a + chunk_b);
                        acc[127:0] <= chunk_sum[127:0];
                        carry      <= chunk_sum[128];
                        chunk      <= 1'b1;
                    end else begin
                        chunk_a   = {1'b0, acc[256:128]};
                        chunk_b   = {1'b0, y[255:128]};
                        chunk_sum = mode_sub ? (chunk_a - chunk_b - {128'd0,carry})
                                              : (chunk_a + chunk_b + {128'd0,carry});
                        acc[256:128] <= chunk_sum[128:0];
                        chunk        <= 1'b0;
                        carry        <= 1'b0;
 
                        if (!mode_sub) begin
                            // add mode always needs the P-reduction check
                            phase <= PH_FIN;
                        end else if (chunk_sum[128]) begin
                            // sub mode, x < y: need +P, one more phase
                            op_borrow <= 1'b1;
                            phase     <= PH_FIN;
                        end else begin
                            // sub mode, x >= y: acc already correct, finish now
                            res  <= {chunk_sum[127:0], acc[127:0]};
                            busy <= 1'b0;
                            done <= 1'b1;
                        end
                    end
                end
 
                //--------------------------------------------------
                // add mode : acc -= P, only if acc >= P
                // sub mode : acc += P   (only reached when x < y)
                //--------------------------------------------------
                PH_FIN: begin
                    if (chunk == 1'b0) begin
                        chunk_a   = {1'b0, acc[127:0]};
                        chunk_b   = {1'b0, P[127:0]};
                        chunk_sum = mode_sub ? (chunk_a + chunk_b) : (chunk_a - chunk_b);
                        stage[127:0] <= chunk_sum[127:0];
                        carry        <= chunk_sum[128];
                        chunk        <= 1'b1;
                    end else begin
                        chunk_a   = {1'b0, acc[256:128]};
                        chunk_b   = {1'b0, P[255:128]};
                        chunk_sum = mode_sub ? (chunk_a + chunk_b + {128'd0,carry})
                                              : (chunk_a - chunk_b - {128'd0,carry});
                        chunk <= 1'b0;
                        carry <= 1'b0;
 
                        if (mode_sub) begin
                            // sub-mode +P correction: always commit, no further check
                            res <= {chunk_sum[127:0], stage[127:0]};
                        end else begin
                            // add-mode P-reduction: commit only if no borrow
                            res <= (!chunk_sum[128]) ? {chunk_sum[127:0], stage[127:0]}
                                                      : acc[255:0];
                        end
                        busy <= 1'b0;
                        done <= 1'b1;
                    end
                end
 
                endcase
            end
        end
    end
 
endmodule
