//`timescale 1ns/1ps
////======================================================================
//// mod_inv_bin_256   (rewritten - now shares one mod_addsub_256 ALU)
////
//// Previously "unchanged / not a contributor" - that assessment was
//// wrong once the engine's own duplication was fixed and the real
//// numbers came back: U_INV alone is 5,011 LUTs. The reason is the
//// same disease the engine had: u<=u-v, v<=v-u, x1<=mod_sub(x1,x2),
//// x2<=mod_sub(x2,x1) are 4 separate inline 256-bit subtractors (2 of
//// them via the mod_sub function, inlined at both call sites), plus 2
//// more adders for the "(x+P)>>1" halving correction - 6 separate
//// arithmetic instances for what is fundamentally a 4-register (u, v,
//// x1, x2) algorithm.
////
//// This version instantiates ONE mod_addsub_256 (same module used by
//// ecc_point_engine_256) and routes the 4 genuine modular subtractions
//// (u-v, v-u, mod_sub(x1,x2), mod_sub(x2,x1)) through it via a 2-cycle
//// dispatch/capture, the same pattern used throughout the engine
//// rewrite. Note that mod_addsub_256's sub=1 mode, res = (x+P-y)
//// corrected by -P if >= P, is *also* the correct answer for a plain
//// "x-y" when x>=y is already guaranteed (as it is for u-v and v-u
//// here, since those branches only fire when u>v or v>=u): (x-y)+P is
//// always >= P in that case, so the single correction step always
//// fires and nets out to exactly x-y. That means u-v, v-u,
//// mod_sub(x1,x2) and mod_sub(x2,x1) can all share the exact same ALU
//// op with no special-casing.
////
//// The "(x+P)>>1" halving correction (used when x1 or x2 is odd, to
//// keep the values even before shifting) is deliberately left as a
//// small local adder, NOT routed through the shared ALU: that step
//// needs the *raw*, unreduced sum x+P, not (x+P) mod P - the whole
//// point is to temporarily push the value above P so the shift works.
//// mod_addsub_256 always normalizes back into [0,P), which would
//// silently cancel the +P. This adder is tiny (used twice, not
//// duplicated across many call sites) and was never the actual
//// resource problem, so it is kept exactly as in the original,
//// working design.
////
//// Binary GCD now costs 2-3 clock cycles per loop iteration instead of
//// 1 (previously free-combinational). The 1024-iteration timeout is
//// unchanged (worst case for 256-bit inputs is well under that), so
//// total added latency is at most a few thousand cycles - negligible
//// next to the ~19,000+ cycle full scalar multiply, and this routine
//// only runs once per scalar multiply (final normalization), not once
//// per ladder bit.
////======================================================================
//module mod_inv_bin_256 #(
//    parameter WIDTH = 256,
//    parameter P =
//    256'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
//)(
//    input clk,
//    input rst,
//    input start,
 
//    input  [WIDTH-1:0] a,
 
//    output reg [WIDTH-1:0] inv,
//    output reg done,
//    output reg busy
//);
 
//reg [WIDTH-1:0] u;
//reg [WIDTH-1:0] v;
//reg [WIDTH-1:0] x1;
//reg [WIDTH-1:0] x2;
 
//reg [11:0] cnt;
 
////--------------------------------------------------
//// Single shared modular add/sub ALU (same module type the point
//// engine uses - this is a second, independent instance local to this
//// module, which still collapses this module's own 6 duplicate inline
//// subtractors down to 1)
////--------------------------------------------------
//reg  [WIDTH-1:0] alu_a, alu_b;
//reg              alu_sub;
//wire [WIDTH-1:0] alu_y;
 
//mod_addsub_256 #(WIDTH,P) U_ALU (
//    .x(alu_a), .y(alu_b), .sub(alu_sub), .res(alu_y)
//);
 
////--------------------------------------------------
//// States
////--------------------------------------------------
//localparam
//    S_IDLE       = 0,
//    S_CHECK      = 1,
//    S_U_SUB1     = 4,   // capture u-v,        dispatch mod_sub(x1,x2)
//    S_U_SUB2     = 5,   // capture x1
//    S_V_SUB1     = 6,   // capture v-u,        dispatch mod_sub(x2,x1)
//    S_V_SUB2     = 7;   // capture x2
 
//reg [3:0] state;
 
////--------------------------------------------------
//// Binary Extended Euclid
////--------------------------------------------------
//always @(posedge clk) begin
 
//    if(rst) begin
 
//        u    <= 0;
//        v    <= 0;
 
//        x1   <= 0;
//        x2   <= 0;
 
//        inv  <= 0;
 
//        cnt  <= 0;
 
//        done <= 0;
//        busy <= 0;
 
//        alu_a <= 0; alu_b <= 0; alu_sub <= 1'b0;
 
//        state <= S_IDLE;
 
//    end
//    else begin
 
//        done <= 1'b0;
 
//        case (state)
 
//        //----------------------------------
//        // Start
//        //----------------------------------
//        S_IDLE: if (start) begin
 
//            if (a == 0) begin
//                inv  <= 0;
//                done <= 1'b1;
//            end
 
//            else if (a == 1) begin
//                inv  <= 1;
//                done <= 1'b1;
//            end
 
//            else begin
 
//                u <= a;
//                v <= P;
 
//                x1 <= 256'd1;
//                x2 <= 256'd0;
 
//                cnt <= 0;
 
//                busy  <= 1'b1;
//                state <= S_CHECK;
//            end
//        end
 
//        //----------------------------------
//        // Top of each loop iteration
//        //----------------------------------
//        S_CHECK: begin
 
//            if (u == 1) begin
//                inv  <= x1;
//                done <= 1'b1;
//                busy <= 1'b0;
//                state <= S_IDLE;
//            end
 
//            else if (v == 1) begin
//                inv  <= x2;
//                done <= 1'b1;
//                busy <= 1'b0;
//                state <= S_IDLE;
//            end
 
//            else if (cnt >= 1024) begin
//                inv  <= 0;
//                done <= 1'b1;
//                busy <= 1'b0;
//                state <= S_IDLE;
//            end
 
//            //----------------------------------
//            // u even  (raw, unreduced (x1+P)>>1 - must NOT use the
//            // modular ALU here, see file header)
//            //----------------------------------
//            else if (!u[0]) begin
//                u <= u >> 1;
//                if (x1[0])
//                    x1 <= (({1'b0,x1} + {1'b0,P}) >> 1);
//                else
//                    x1 <= x1 >> 1;
//                cnt <= cnt + 1'b1;
//                // stay in S_CHECK
//            end
 
//            //----------------------------------
//            // v even  (raw, unreduced (x2+P)>>1 - must NOT use the
//            // modular ALU here, see file header)
//            //----------------------------------
//            else if (!v[0]) begin
//                v <= v >> 1;
//                if (x2[0])
//                    x2 <= (({1'b0,x2} + {1'b0,P}) >> 1);
//                else
//                    x2 <= x2 >> 1;
//                cnt <= cnt + 1'b1;
//                // stay in S_CHECK
//            end
 
//            //----------------------------------
//            // u > v
//            //----------------------------------
//            else if (u > v) begin
//                alu_a <= u; alu_b <= v; alu_sub <= 1'b1;        // u-v
//                state <= S_U_SUB1;
//            end
 
//            //----------------------------------
//            // v >= u
//            //----------------------------------
//            else begin
//                alu_a <= v; alu_b <= u; alu_sub <= 1'b1;        // v-u
//                state <= S_V_SUB1;
//            end
//        end
 
//        //----------------------------------
//        // u > v :  u <= u-v ; x1 <= mod_sub(x1,x2)
//        //----------------------------------
//        S_U_SUB1: begin
//            u <= alu_y;
//            alu_a <= x1; alu_b <= x2; alu_sub <= 1'b1;
//            state <= S_U_SUB2;
//        end
 
//        S_U_SUB2: begin
//            x1  <= alu_y;
//            cnt <= cnt + 1'b1;
//            state <= S_CHECK;
//        end
 
//        //----------------------------------
//        // v >= u :  v <= v-u ; x2 <= mod_sub(x2,x1)
//        //----------------------------------
//        S_V_SUB1: begin
//            v <= alu_y;
//            alu_a <= x2; alu_b <= x1; alu_sub <= 1'b1;
//            state <= S_V_SUB2;
//        end
 
//        S_V_SUB2: begin
//            x2  <= alu_y;
//            cnt <= cnt + 1'b1;
//            state <= S_CHECK;
//        end
 
//        default: state <= S_IDLE;
 
//        endcase
//    end
//end
 
//endmodule

//`timescale 1ns/1ps
////======================================================================
//// mod_inv_bin_256   (now shares the ENGINE's mod_addsub_256 instead of
//// owning its own - one full 256-bit add/sub tree removed from the
//// design; math and results are unchanged, only latency per iteration
//// grows slightly, which is negligible since this runs once per scalar
//// multiply, not once per ladder bit)
////======================================================================
//module mod_inv_bin_256 #(
//    parameter WIDTH = 256,
//    parameter P =
//    256'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
//)(
//    input clk,
//    input rst,
//    input start,

//    input  [WIDTH-1:0] a,

//    output reg [WIDTH-1:0] inv,
//    output reg done,
//    output reg busy,

//    // ------------------------------------------------------------
//    // Shared-ALU request interface - routed through the engine's
//    // mod_addsub_256 instance (see ecc_point_engine_256's alu_ext_*
//    // ports). This module no longer instantiates its own ALU.
//    // ------------------------------------------------------------
//    output reg               alu_req_start,
//    output reg [WIDTH-1:0]    alu_req_a,
//    output reg [WIDTH-1:0]    alu_req_b,
//    output reg                alu_req_sub,
//    input      [WIDTH-1:0]    alu_res,
//    input                      alu_done
//);

//reg [WIDTH-1:0] u;
//reg [WIDTH-1:0] v;
//reg [WIDTH-1:0] x1;
//reg [WIDTH-1:0] x2;

//reg [11:0] cnt;

////--------------------------------------------------
//// States
////--------------------------------------------------
//localparam
//    S_IDLE        = 0,
//    S_CHECK       = 1,
//    S_U_SUB1_WAIT = 4,   // waiting for u-v,               then dispatch mod_sub(x1,x2)
//    S_U_SUB2_WAIT = 5,   // waiting for mod_sub(x1,x2)
//    S_V_SUB1_WAIT = 6,   // waiting for v-u,                then dispatch mod_sub(x2,x1)
//    S_V_SUB2_WAIT = 7;   // waiting for mod_sub(x2,x1)

//reg [3:0] state;

////--------------------------------------------------
//// Binary Extended Euclid
////--------------------------------------------------
//always @(posedge clk) begin

//    if(rst) begin

//        u    <= 0;
//        v    <= 0;

//        x1   <= 0;
//        x2   <= 0;

//        inv  <= 0;

//        cnt  <= 0;

//        done <= 0;
//        busy <= 0;

//        alu_req_start <= 1'b0;
//        alu_req_a     <= 0;
//        alu_req_b     <= 0;
//        alu_req_sub   <= 1'b0;

//        state <= S_IDLE;

//    end
//    else begin

//        done <= 1'b0;
//        alu_req_start <= 1'b0;   // default-deassert each cycle (pulse)

//        case (state)

//        //----------------------------------
//        // Start
//        //----------------------------------
//        S_IDLE: if (start) begin

//            if (a == 0) begin
//                inv  <= 0;
//                done <= 1'b1;
//            end

//            else if (a == 1) begin
//                inv  <= 1;
//                done <= 1'b1;
//            end

//            else begin

//                u <= a;
//                v <= P;

//                x1 <= 256'd1;
//                x2 <= 256'd0;

//                cnt <= 0;

//                busy  <= 1'b1;
//                state <= S_CHECK;
//            end
//        end

//        //----------------------------------
//        // Top of each loop iteration
//        //----------------------------------
//        S_CHECK: begin

//            if (u == 1) begin
//                inv  <= x1;
//                done <= 1'b1;
//                busy <= 1'b0;
//                state <= S_IDLE;
//            end

//            else if (v == 1) begin
//                inv  <= x2;
//                done <= 1'b1;
//                busy <= 1'b0;
//                state <= S_IDLE;
//            end

//            else if (cnt >= 1024) begin
//                inv  <= 0;
//                done <= 1'b1;
//                busy <= 1'b0;
//                state <= S_IDLE;
//            end

//            //----------------------------------
//            // u even  (raw, unreduced (x1+P)>>1 - must NOT use the
//            // modular ALU here - see original design notes)
//            //----------------------------------
//            else if (!u[0]) begin
//                u <= u >> 1;
//                if (x1[0])
//                    x1 <= (({1'b0,x1} + {1'b0,P}) >> 1);
//                else
//                    x1 <= x1 >> 1;
//                cnt <= cnt + 1'b1;
//                // stay in S_CHECK
//            end

//            //----------------------------------
//            // v even  (raw, unreduced (x2+P)>>1 - must NOT use the
//            // modular ALU here - see original design notes)
//            //----------------------------------
//            else if (!v[0]) begin
//                v <= v >> 1;
//                if (x2[0])
//                    x2 <= (({1'b0,x2} + {1'b0,P}) >> 1);
//                else
//                    x2 <= x2 >> 1;
//                cnt <= cnt + 1'b1;
//                // stay in S_CHECK
//            end

//            //----------------------------------
//            // u > v
//            //----------------------------------
//            else if (u > v) begin
//                alu_req_a <= u; alu_req_b <= v; alu_req_sub <= 1'b1;
//                alu_req_start <= 1'b1;
//                state <= S_U_SUB1_WAIT;
//            end

//            //----------------------------------
//            // v >= u
//            //----------------------------------
//            else begin
//                alu_req_a <= v; alu_req_b <= u; alu_req_sub <= 1'b1;
//                alu_req_start <= 1'b1;
//                state <= S_V_SUB1_WAIT;
//            end
//        end

//        //----------------------------------
//        // u > v :  u <= u-v ; x1 <= mod_sub(x1,x2)
//        //----------------------------------
//        S_U_SUB1_WAIT: if (alu_done) begin
//            u <= alu_res;
//            alu_req_a <= x1; alu_req_b <= x2; alu_req_sub <= 1'b1;
//            alu_req_start <= 1'b1;
//            state <= S_U_SUB2_WAIT;
//        end

//        S_U_SUB2_WAIT: if (alu_done) begin
//            x1  <= alu_res;
//            cnt <= cnt + 1'b1;
//            state <= S_CHECK;
//        end

//        //----------------------------------
//        // v >= u :  v <= v-u ; x2 <= mod_sub(x2,x1)
//        //----------------------------------
//        S_V_SUB1_WAIT: if (alu_done) begin
//            v <= alu_res;
//            alu_req_a <= x2; alu_req_b <= x1; alu_req_sub <= 1'b1;
//            alu_req_start <= 1'b1;
//            state <= S_V_SUB2_WAIT;
//        end

//        S_V_SUB2_WAIT: if (alu_done) begin
//            x2  <= alu_res;
//            cnt <= cnt + 1'b1;
//            state <= S_CHECK;
//        end

//        default: state <= S_IDLE;

//        endcase
//    end
//end

//endmodule



`timescale 1ns/1ps
`default_nettype wire
//======================================================================
// mod_inv_bin_256   (shares the ENGINE's mod_addsub_256 instead of
// owning its own - one full 256-bit add/sub tree removed from the
// design. Uses a request/ack handshake with the engine's alu_ext_*
// ports, so it needs no changes when the underlying ALU's internal
// latency changes (e.g. the word-serial conversion) - it already
// waits for alu_done rather than assuming instant completion.)
//======================================================================
module mod_inv_bin_256 #(
    parameter WIDTH = 256,
    parameter P =
    256'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
)(
    input clk,
    input rst,
    input start,
 
    input  [WIDTH-1:0] a,
 
    output reg [WIDTH-1:0] inv,
    output reg done,
    output reg busy,
 
    // ------------------------------------------------------------
    // Shared-ALU request interface - routed through the engine's
    // mod_addsub_256 instance (see ecc_point_engine_256's alu_ext_*
    // ports). This module does not instantiate its own ALU.
    // ------------------------------------------------------------
    output reg               alu_req_start,
    output reg [WIDTH-1:0]    alu_req_a,
    output reg [WIDTH-1:0]    alu_req_b,
    output reg                alu_req_sub,
    input      [WIDTH-1:0]    alu_res,
    input                      alu_done
);
 
reg [WIDTH-1:0] u;
reg [WIDTH-1:0] v;
reg [WIDTH-1:0] x1;
reg [WIDTH-1:0] x2;
 
reg [11:0] cnt;
 
//--------------------------------------------------
// States
//--------------------------------------------------
localparam
    S_IDLE        = 0,
    S_CHECK       = 1,
    S_U_SUB1_WAIT = 4,   // waiting for u-v,               then dispatch mod_sub(x1,x2)
    S_U_SUB2_WAIT = 5,   // waiting for mod_sub(x1,x2)
    S_V_SUB1_WAIT = 6,   // waiting for v-u,                then dispatch mod_sub(x2,x1)
    S_V_SUB2_WAIT = 7;   // waiting for mod_sub(x2,x1)
 
reg [3:0] state;
 
//--------------------------------------------------
// Binary Extended Euclid
//--------------------------------------------------
always @(posedge clk) begin
 
    if(rst) begin
 
        u    <= 0;
        v    <= 0;
 
        x1   <= 0;
        x2   <= 0;
 
        inv  <= 0;
 
        cnt  <= 0;
 
        done <= 0;
        busy <= 0;
 
        alu_req_start <= 1'b0;
        alu_req_a     <= 0;
        alu_req_b     <= 0;
        alu_req_sub   <= 1'b0;
 
        state <= S_IDLE;
 
    end
    else begin
 
        done <= 1'b0;
        alu_req_start <= 1'b0;   // default-deassert each cycle (pulse)
 
        case (state)
 
        //----------------------------------
        // Start
        //----------------------------------
        S_IDLE: if (start) begin
 
            if (a == 0) begin
                inv  <= 0;
                done <= 1'b1;
            end
 
            else if (a == 1) begin
                inv  <= 1;
                done <= 1'b1;
            end
 
            else begin
 
                u <= a;
                v <= P;
 
                x1 <= 256'd1;
                x2 <= 256'd0;
 
                cnt <= 0;
 
                busy  <= 1'b1;
                state <= S_CHECK;
            end
        end
 
        //----------------------------------
        // Top of each loop iteration
        //----------------------------------
        S_CHECK: begin
 
            if (u == 1) begin
                inv  <= x1;
                done <= 1'b1;
                busy <= 1'b0;
                state <= S_IDLE;
            end
 
            else if (v == 1) begin
                inv  <= x2;
                done <= 1'b1;
                busy <= 1'b0;
                state <= S_IDLE;
            end
 
            else if (cnt >= 1024) begin
                inv  <= 0;
                done <= 1'b1;
                busy <= 1'b0;
                state <= S_IDLE;
            end
 
            //----------------------------------
            // u even  (raw, unreduced (x1+P)>>1 - must NOT use the
            // modular ALU here - see original design notes)
            //----------------------------------
            else if (!u[0]) begin
                u <= u >> 1;
                if (x1[0])
                    x1 <= (({1'b0,x1} + {1'b0,P}) >> 1);
                else
                    x1 <= x1 >> 1;
                cnt <= cnt + 1'b1;
                // stay in S_CHECK
            end
 
            //----------------------------------
            // v even  (raw, unreduced (x2+P)>>1 - must NOT use the
            // modular ALU here - see original design notes)
            //----------------------------------
            else if (!v[0]) begin
                v <= v >> 1;
                if (x2[0])
                    x2 <= (({1'b0,x2} + {1'b0,P}) >> 1);
                else
                    x2 <= x2 >> 1;
                cnt <= cnt + 1'b1;
                // stay in S_CHECK
            end
 
            //----------------------------------
            // u > v
            //----------------------------------
            else if (u > v) begin
                alu_req_a <= u; alu_req_b <= v; alu_req_sub <= 1'b1;
                alu_req_start <= 1'b1;
                state <= S_U_SUB1_WAIT;
            end
 
            //----------------------------------
            // v >= u
            //----------------------------------
            else begin
                alu_req_a <= v; alu_req_b <= u; alu_req_sub <= 1'b1;
                alu_req_start <= 1'b1;
                state <= S_V_SUB1_WAIT;
            end
        end
 
        //----------------------------------
        // u > v :  u <= u-v ; x1 <= mod_sub(x1,x2)
        //----------------------------------
        S_U_SUB1_WAIT: if (alu_done) begin
            u <= alu_res;
            alu_req_a <= x1; alu_req_b <= x2; alu_req_sub <= 1'b1;
            alu_req_start <= 1'b1;
            state <= S_U_SUB2_WAIT;
        end
 
        S_U_SUB2_WAIT: if (alu_done) begin
            x1  <= alu_res;
            cnt <= cnt + 1'b1;
            state <= S_CHECK;
        end
 
        //----------------------------------
        // v >= u :  v <= v-u ; x2 <= mod_sub(x2,x1)
        //----------------------------------
        S_V_SUB1_WAIT: if (alu_done) begin
            v <= alu_res;
            alu_req_a <= x2; alu_req_b <= x1; alu_req_sub <= 1'b1;
            alu_req_start <= 1'b1;
            state <= S_V_SUB2_WAIT;
        end
 
        S_V_SUB2_WAIT: if (alu_done) begin
            x2  <= alu_res;
            cnt <= cnt + 1'b1;
            state <= S_CHECK;
        end
 
        default: state <= S_IDLE;
 
        endcase
    end
end
 
endmodule