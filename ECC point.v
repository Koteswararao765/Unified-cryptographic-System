//`timescale 1ns/1ps
////======================================================================
//// ecc_point_engine_256   (rewritten for real resource sharing)
////
//// Port list, module name and parameters are UNCHANGED from your
//// working version, so top.v needs no edits and tb_ecc_func_80.v
//// (which only ever touches the top-level DUT, not this module)
//// keeps working with zero edits.
////
//// WHAT CHANGED VS. THE PREVIOUS VERSION AND WHY
//// -----------------------------------------------------------------
//// The previous engine already collapsed doubling+addition into one
//// module and used a single mod_mult_iter_256 instance - good moves.
//// But mod_add / mod_sub / mod_dbl were Verilog *functions*. Functions
//// are inlined at every call site; Vivado does not merge them into one
//// physical adder unless you force it to. With ~30 call sites spread
//// across the doubling flow and the addition flow, that alone was
//// building ~30 duplicate 256-bit adder/subtractor/comparator trees,
//// which is the real reason U_ENG synthesized to 21,604 LUTs (over the
//// xc7a35t's 20,800-LUT budget) even though the multiplier itself was
//// already a single shared instance.
////
//// This version fixes that the same way the multiplier was already
//// fixed:
////   1. mod_addsub_256 is instantiated ONCE (see mod_addsub_256.txt).
////      Every modular add/sub anywhere in this engine is now a
////      2-cycle "dispatch -> capture" through that ONE instance,
////      exactly the same dispatch/wait pattern already used for the
////      multiplier (ma/mb/mul_start -> mul_done/mul_res). This is a
////      hard N:1 reduction in add/sub hardware.
////   2. The doubling flow's 13 "d_*" temporaries and the addition
////      flow's ~19 temporaries were 28+ separately-named 256-bit
////      registers that are NEVER live at the same time (the two flows
////      never run concurrently - this is the same fact the previous
////      version already relied on when it re-entered the doubling
////      flow for the P==P collision case instead of building a second
////      doubler). They are now a single shared scratch pool t0..t12
////      (13 registers) reused by BOTH flows, roughly halving the
////      temporary-register/mux footprint.
////
//// The underlying math is untouched: dbl-2009-l (a=0 curve) for
//// doubling, add-2007-bl for general addition, same intermediate
//// quantities (YY, S, M, HH, HHH, V, R, ...) in the same order - so
//// results are bit-for-bit identical to your functionally-verified
//// design. Only the hardware used to compute each step, and the exact
//// cycle count it takes, has changed (more cycles, much less area -
//// a deliberate area/latency trade, consistent with the "resource
//// sharing" / "low power" objectives in the report; the extra cycles
//// are a rounding error next to the ~256-cycle multiplies).
////======================================================================
//module ecc_point_engine_256 #(
//    parameter WIDTH = 256,
//    parameter P =
//    256'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
//)(
//    input clk,
//    input rst,
 
//    input start,
//    input op,               // 0 = DOUBLE (uses X1,Y1,Z1,X1_inf only)
//                             // 1 = ADD    (X1,Y1,Z1,X1_inf + X2,Y2,Z2,X2_inf)
 
//    input [WIDTH-1:0] X1,
//    input [WIDTH-1:0] Y1,
//    input [WIDTH-1:0] Z1,
//    input             X1_inf,
 
//    input [WIDTH-1:0] X2,
//    input [WIDTH-1:0] Y2,
//    input [WIDTH-1:0] Z2,
//    input             X2_inf,
 
//    output reg [WIDTH-1:0] X3,
//    output reg [WIDTH-1:0] Y3,
//    output reg [WIDTH-1:0] Z3,
//    output reg              X3_inf,
 
//    output reg done,
//    output reg busy,
 
//    // ------------------------------------------------------------
//    // Shared-multiplier passthrough: lets the top level reuse THIS
//    // single multiplier instance for final-coordinate normalization
//    // instead of instantiating a separate one. Only usable while the
//    // engine is idle (busy == 0); the top-level FSM only ever drives
//    // this after the Montgomery ladder has finished, so there is no
//    // contention in practice. (Unchanged from the previous version.)
//    // ------------------------------------------------------------
//    input                    ext_start,
//    input      [WIDTH-1:0]   ext_a,
//    input      [WIDTH-1:0]   ext_b,
//    output reg [WIDTH-1:0]   ext_res,
//    output reg               ext_done
//);
 
////--------------------------------------------------
//// Single shared multiplier (unchanged - already one instance)
////--------------------------------------------------
//reg  [WIDTH-1:0] ma, mb;
//reg              mul_start;
//wire [WIDTH-1:0] mul_res;
//wire             mul_done;
//wire             mul_busy;
 
//mod_mult_iter_256 #(WIDTH,P) U_MUL (
//    .clk(clk), .rst(rst),
//    .start(mul_start),
//    .a(ma), .b(mb),
//    .res(mul_res), .done(mul_done), .busy(mul_busy)
//);
 
////--------------------------------------------------
//// Single shared modular add/sub ALU (NEW - replaces ~30 inlined
//// mod_add/mod_sub/mod_dbl function call sites with ONE instance)
////--------------------------------------------------
//reg  [WIDTH-1:0] alu_a, alu_b;
//reg              alu_sub;
//wire [WIDTH-1:0] alu_y;
 
//mod_addsub_256 #(WIDTH,P) U_ALU (
//    .x(alu_a), .y(alu_b), .sub(alu_sub), .res(alu_y)
//);
 
////--------------------------------------------------
//// Shared scratch pool - reused by BOTH the doubling flow and the
//// addition flow (they never run at the same time)
////--------------------------------------------------
//reg [WIDTH-1:0] t0, t1, t2, t3, t4, t5, t6, t7, t8, t9, t10, t11, t12;
 
////--------------------------------------------------
//// States
////--------------------------------------------------
//localparam
//    E_IDLE      = 0,
//    E_EXT_W     = 1,
 
//    // ---- doubling flow (also reused for the add-collision case) ----
//    E_D_ENTRY   = 2,
//    E_D1        = 3,   // capture YY,           dispatch XYY  mul
//    E_D2        = 4,   // capture XYY,          dispatch 2*XYY alu
//    E_D3        = 5,   // capture 2*XYY,        dispatch 4*XYY alu
//    E_D4        = 6,   // capture S=4*XYY,      dispatch XX   mul
//    E_D5        = 7,   // capture XX,           dispatch 2*XX alu
//    E_D6        = 8,   // capture 2*XX(Mt),     dispatch Mt+XX alu
//    E_D7        = 9,   // capture M=3*XX,       dispatch M*M  mul
//    E_D8        = 10,  // capture M2,           dispatch 2*S  alu
//    E_D9        = 11,  // capture S2=2*S,       dispatch M2-S2 alu
//    E_D10       = 12,  // capture X3=M2-S2,     dispatch S-X3  alu
//    E_D11       = 13,  // capture SX3=S-X3,     dispatch M*SX3 mul
//    E_D12       = 14,  // capture T=M*SX3,      dispatch YY*YY mul
//    E_D13       = 15,  // capture YY2,          dispatch 2*YY2 alu
//    E_D14       = 16,  // capture 2*YY2,        dispatch 4*YY2 alu
//    E_D15       = 17,  // capture 4*YY2,        dispatch 8*YY2 alu
//    E_D16       = 18,  // capture YY8=8*YY2,    dispatch T-YY8 alu
//    E_D17       = 19,  // capture Y3=T-YY8,     dispatch Y1*Z1 mul
//    E_D18       = 20,  // capture Z3raw,        dispatch 2*Z3raw alu
//    E_D19       = 21,  // capture Z3=2*Z3raw,   done
 
//    // ---- addition flow (add-2007-bl) ----
//    E_A_ENTRY   = 30,
//    E_A1        = 31,  // dispatch Z1*Z1 mul
//    E_A2        = 32,  // capture Z1Z1,   dispatch Z2*Z2 mul
//    E_A3        = 33,  // capture Z2Z2,   dispatch X1*Z2Z2 mul (U1)
//    E_A4        = 34,  // capture U1,     dispatch X2*Z1Z1 mul (U2)
//    E_A5        = 35,  // capture U2,     dispatch Z1*Z1Z1 mul (Z1CUBE)
//    E_A6        = 36,  // capture Z1CUBE, dispatch Z2*Z2Z2 mul (Z2CUBE)
//    E_A7        = 37,  // capture Z2CUBE, dispatch Y1*Z2CUBE mul (S1)
//    E_A8        = 38,  // capture S1,     dispatch Y2*Z1CUBE mul (S2)
//    E_A9        = 39,  // capture S2,     dispatch U2-U1 alu (H)
//    E_A10       = 40,  // capture H,      dispatch S2-S1 alu (R)
//    E_A11       = 41,  // capture R, decide collision / infinity / continue
//    E_A12       = 42,  // capture H*H(HH) started at A11-else, wait mul
//    E_A13       = 43,  // capture HH,     dispatch H*HH mul (HHH)
//    E_A14       = 44,  // capture HHH,    dispatch U1*HH mul (V)
//    E_A15       = 45,  // capture V,      dispatch R*R  mul (R2)
//    E_A16       = 46,  // capture R2, dispatch R2-HHH alu (X3_tmp)
//    E_A17       = 47,  // capture X3_tmp, dispatch 2*V alu (V2)
//    E_A18       = 48,  // capture V2,     dispatch X3_tmp-V2 alu (X3)
//    E_A19       = 49,  // capture X3,     dispatch V-X3 alu (VX3)
//    E_A20       = 50,  // capture VX3,    dispatch R*VX3 mul (RVX)
//    E_A21       = 51,  // capture RVX,    dispatch S1*HHH mul (S1HHH)
//    E_A22       = 52,  // capture S1HHH,  dispatch RVX-S1HHH alu (Y3)
//    E_A23       = 53,  // capture Y3,     dispatch H*Z1 mul (Z3a)
//    E_A24       = 54,  // capture Z3a,    dispatch Z3a*Z2 mul (Z3)
//    E_A25       = 55,  // capture Z3, done
 
//    E_DONE      = 63;
 
//reg [7:0] state;
 
//always @(posedge clk) begin
 
//    if (rst) begin
 
//        state     <= E_IDLE;
//        busy      <= 1'b0;
//        done      <= 1'b0;
//        mul_start <= 1'b0;
 
//        alu_a <= 0; alu_b <= 0; alu_sub <= 1'b0;
//        ma <= 0; mb <= 0;
 
//        t0<=0; t1<=0; t2<=0; t3<=0; t4<=0; t5<=0; t6<=0;
//        t7<=0; t8<=0; t9<=0; t10<=0; t11<=0; t12<=0;
 
//        X3 <= 0; Y3 <= 0; Z3 <= 0; X3_inf <= 1'b0;
 
//        ext_res  <= 0;
//        ext_done <= 1'b0;
 
//    end else begin
 
//        done      <= 1'b0;
//        mul_start <= 1'b0;
//        ext_done  <= 1'b0;
 
//        case (state)
 
//        //==================================================
//        // IDLE / dispatch
//        //==================================================
//        E_IDLE: begin
//            if (start && !busy) begin
//                busy <= 1'b1;
//                if (op == 1'b0)
//                    state <= E_D_ENTRY;
//                else
//                    state <= E_A_ENTRY;
//            end
//            else if (ext_start) begin
//                busy      <= 1'b1;
//                ma        <= ext_a;
//                mb        <= ext_b;
//                mul_start <= 1'b1;
//                state     <= E_EXT_W;
//            end
//        end
 
//        E_EXT_W: begin
//            if (mul_done) begin
//                ext_res  <= mul_res;
//                ext_done <= 1'b1;
//                busy     <= 1'b0;
//                state    <= E_IDLE;
//            end
//        end
 
//        //==================================================
//        // DOUBLING FLOW  (dbl-2009-l, a = 0)
//        //   YY  = Y1^2
//        //   S   = 4*X1*YY
//        //   M   = 3*X1^2
//        //   M2  = M^2
//        //   X3  = M2 - 2S
//        //   T   = M*(S - X3)
//        //   YY2 = YY^2
//        //   Y3  = T - 8*YY2
//        //   Z3  = 2*Y1*Z1
//        //==================================================
//        E_D_ENTRY: begin
//            if (X1_inf || (Y1 == 0)) begin
//                X3 <= 0; Y3 <= 1; Z3 <= 0; X3_inf <= 1'b1;
//                busy <= 1'b0; done <= 1'b1;
//                state <= E_IDLE;
//            end else begin
//                ma <= Y1; mb <= Y1; mul_start <= 1'b1;   // YY = Y1*Y1
//                state <= E_D1;
//            end
//        end
 
//        E_D1: if (mul_done) begin
//            t0 <= mul_res;                                // YY
//            ma <= X1; mb <= mul_res; mul_start <= 1'b1;    // XYY = X1*YY
//            state <= E_D2;
//        end
 
//        E_D2: if (mul_done) begin
//            t1 <= mul_res;                                 // XYY
//            alu_a <= mul_res; alu_b <= mul_res; alu_sub <= 1'b0;  // 2*XYY
//            state <= E_D3;
//        end
 
//        E_D3: begin
//            t2 <= alu_y;                                    // 2*XYY
//            alu_a <= alu_y; alu_b <= alu_y; alu_sub <= 1'b0; // 4*XYY
//            state <= E_D4;
//        end
 
//        E_D4: begin
//            t2 <= alu_y;                                     // S = 4*XYY
//            ma <= X1; mb <= X1; mul_start <= 1'b1;            // XX = X1*X1
//            state <= E_D5;
//        end
 
//        E_D5: if (mul_done) begin
//            t3 <= mul_res;                                    // XX
//            alu_a <= mul_res; alu_b <= mul_res; alu_sub <= 1'b0; // 2*XX
//            state <= E_D6;
//        end
 
//        E_D6: begin
//            t4 <= alu_y;                                      // Mt = 2*XX
//            alu_a <= alu_y; alu_b <= t3; alu_sub <= 1'b0;      // M = Mt+XX
//            state <= E_D7;
//        end
 
//        E_D7: begin
//            t4 <= alu_y;                                      // M = 3*XX
//            ma <= alu_y; mb <= alu_y; mul_start <= 1'b1;       // M2 = M*M
//            state <= E_D8;
//        end
 
//        E_D8: if (mul_done) begin
//            t5 <= mul_res;                                    // M2
//            alu_a <= t2; alu_b <= t2; alu_sub <= 1'b0;         // S2 = 2*S
//            state <= E_D9;
//        end
 
//        E_D9: begin
//            t6 <= alu_y;                                       // S2
//            alu_a <= t5; alu_b <= alu_y; alu_sub <= 1'b1;       // X3=M2-S2
//            state <= E_D10;
//        end
 
//        E_D10: begin
//            X3 <= alu_y;                                        // X3
//            alu_a <= t2; alu_b <= alu_y; alu_sub <= 1'b1;        // SX3=S-X3
//            state <= E_D11;
//        end
 
//        E_D11: begin
//            t8 <= alu_y;                                         // SX3
//            ma <= t4; mb <= alu_y; mul_start <= 1'b1;             // T=M*SX3
//            state <= E_D12;
//        end
 
//        E_D12: if (mul_done) begin
//            t9 <= mul_res;                                       // T
//            ma <= t0; mb <= t0; mul_start <= 1'b1;                // YY2=YY*YY
//            state <= E_D13;
//        end
 
//        E_D13: if (mul_done) begin
//            t10 <= mul_res;                                      // YY2
//            alu_a <= mul_res; alu_b <= mul_res; alu_sub <= 1'b0;  // 2*YY2
//            state <= E_D14;
//        end
 
//        E_D14: begin
//            t11 <= alu_y;                                         // 2*YY2
//            alu_a <= alu_y; alu_b <= alu_y; alu_sub <= 1'b0;       // 4*YY2
//            state <= E_D15;
//        end
 
//        E_D15: begin
//            t11 <= alu_y;                                          // 4*YY2
//            alu_a <= alu_y; alu_b <= alu_y; alu_sub <= 1'b0;        // 8*YY2
//            state <= E_D16;
//        end
 
//        E_D16: begin
//            t11 <= alu_y;                                          // YY8
//            alu_a <= t9; alu_b <= alu_y; alu_sub <= 1'b1;           // T-YY8
//            state <= E_D17;
//        end
 
//        E_D17: begin
//            Y3 <= alu_y;                                           // Y3
//            ma <= Y1; mb <= Z1; mul_start <= 1'b1;                  // Y1*Z1
//            state <= E_D18;
//        end
 
//        E_D18: if (mul_done) begin
//            t12 <= mul_res;                                        // Z3raw
//            alu_a <= mul_res; alu_b <= mul_res; alu_sub <= 1'b0;    // 2*Z3raw
//            state <= E_D19;
//        end
 
//        E_D19: begin
//            Z3     <= alu_y;                                       // Z3
//            X3_inf <= 1'b0;
//            busy   <= 1'b0;
//            done   <= 1'b1;
//            state  <= E_IDLE;
//        end
 
//        //==================================================
//        // ADDITION FLOW  (Jacobian general addition, add-2007-bl)
//        //==================================================
//        E_A_ENTRY: begin
//            if (X1_inf) begin
//                X3 <= X2; Y3 <= Y2; Z3 <= Z2; X3_inf <= X2_inf;
//                busy <= 1'b0; done <= 1'b1; state <= E_IDLE;
//            end else if (X2_inf) begin
//                X3 <= X1; Y3 <= Y1; Z3 <= Z1; X3_inf <= X1_inf;
//                busy <= 1'b0; done <= 1'b1; state <= E_IDLE;
//            end else begin
//                ma <= Z1; mb <= Z1; mul_start <= 1'b1;              // Z1Z1
//                state <= E_A1;
//            end
//        end
 
//        E_A1: if (mul_done) begin
//            t0 <= mul_res;                                          // Z1Z1
//            ma <= Z2; mb <= Z2; mul_start <= 1'b1;                  // Z2Z2
//            state <= E_A2;
//        end
 
//        E_A2: if (mul_done) begin
//            t1 <= mul_res;                                          // Z2Z2
//            ma <= X1; mb <= mul_res; mul_start <= 1'b1;              // U1
//            state <= E_A3;
//        end
 
//        E_A3: if (mul_done) begin
//            t2 <= mul_res;                                          // U1
//            ma <= X2; mb <= t0; mul_start <= 1'b1;                   // U2
//            state <= E_A4;
//        end
 
//        E_A4: if (mul_done) begin
//            t3 <= mul_res;                                          // U2
//            ma <= Z1; mb <= t0; mul_start <= 1'b1;                   // Z1CUBE
//            state <= E_A5;
//        end
 
//        E_A5: if (mul_done) begin
//            t4 <= mul_res;                                          // Z1CUBE
//            ma <= Z2; mb <= t1; mul_start <= 1'b1;                   // Z2CUBE
//            state <= E_A6;
//        end
 
//        E_A6: if (mul_done) begin
//            t5 <= mul_res;                                          // Z2CUBE
//            ma <= Y1; mb <= mul_res; mul_start <= 1'b1;              // S1
//            state <= E_A7;
//        end
 
//        E_A7: if (mul_done) begin
//            t6 <= mul_res;                                          // S1
//            ma <= Y2; mb <= t4; mul_start <= 1'b1;                   // S2
//            state <= E_A8;
//        end
 
//        E_A8: if (mul_done) begin
//            t7 <= mul_res;                                          // S2
//            alu_a <= t3; alu_b <= t2; alu_sub <= 1'b1;                // H=U2-U1
//            state <= E_A9;
//        end
 
//        E_A9: begin
//            t8 <= alu_y;                                             // H
//            alu_a <= t7; alu_b <= t6; alu_sub <= 1'b1;                // R=S2-S1
//            state <= E_A10;
//        end
 
//        E_A10: begin
//            // t8 already holds H (registered on the previous edge).
//            // alu_y right now is R (dispatched from alu_a/b set above
//            // last cycle... actually set THIS cycle, valid next cycle -
//            // so capture/decide happens in E_A11).
//            t9 <= alu_y;
//            state <= E_A11;
//        end
 
//        E_A11: begin
//            if (t8 == 0) begin
//                if (t9 == 0) begin
//                    // P1 == P2 : fall through into the SAME doubling
//                    // datapath used above - no second doubler needed.
//                    state <= E_D_ENTRY;
//                end else begin
//                    X3 <= 0; Y3 <= 1; Z3 <= 0; X3_inf <= 1'b1;
//                    busy <= 1'b0; done <= 1'b1; state <= E_IDLE;
//                end
//            end else begin
//                ma <= t8; mb <= t8; mul_start <= 1'b1;                // HH=H*H
//                state <= E_A12;
//            end
//        end
 
//        E_A12: if (mul_done) begin
//            t10 <= mul_res;                                          // HH
//            ma <= t8; mb <= mul_res; mul_start <= 1'b1;               // HHH
//            state <= E_A13;
//        end
 
//        E_A13: if (mul_done) begin
//            t11 <= mul_res;                                          // HHH
//            ma <= t2; mb <= t10; mul_start <= 1'b1;                   // V=U1*HH
//            state <= E_A14;
//        end
 
//        E_A14: if (mul_done) begin
//            t12 <= mul_res;                                          // V
//            ma <= t9; mb <= t9; mul_start <= 1'b1;                    // R2=R*R
//            state <= E_A15;
//        end
 
//        E_A15: if (mul_done) begin
//            alu_a <= mul_res; alu_b <= t11; alu_sub <= 1'b1;          // R2-HHH
//            state <= E_A16;
//        end
 
//        E_A16: begin
//            t0 <= alu_y;                                              // X3_tmp
//            alu_a <= t12; alu_b <= t12; alu_sub <= 1'b0;               // 2*V
//            state <= E_A17;
//        end
 
//        E_A17: begin
//            t1 <= alu_y;                                              // V2
//            alu_a <= t0; alu_b <= alu_y; alu_sub <= 1'b1;              // X3
//            state <= E_A18;
//        end
 
//        E_A18: begin
//            X3 <= alu_y;                                              // X3
//            alu_a <= t12; alu_b <= alu_y; alu_sub <= 1'b1;             // V-X3
//            state <= E_A19;
//        end
 
//        E_A19: begin
//            t2 <= alu_y;                                              // VX3
//            ma <= t9; mb <= alu_y; mul_start <= 1'b1;                  // R*VX3
//            state <= E_A20;
//        end
 
//        E_A20: if (mul_done) begin
//            t3 <= mul_res;                                            // RVX
//            ma <= t6; mb <= t11; mul_start <= 1'b1;                    // S1*HHH
//            state <= E_A21;
//        end
 
//        E_A21: if (mul_done) begin
//            t4 <= mul_res;                                            // S1HHH
//            alu_a <= t3; alu_b <= mul_res; alu_sub <= 1'b1;            // Y3
//            state <= E_A22;
//        end
 
//        E_A22: begin
//            Y3 <= alu_y;                                              // Y3
//            ma <= t8; mb <= Z1; mul_start <= 1'b1;                     // H*Z1
//            state <= E_A23;
//        end
 
//        E_A23: if (mul_done) begin
//            t0 <= mul_res;                                            // Z3a
//            ma <= mul_res; mb <= Z2; mul_start <= 1'b1;                 // Z3a*Z2
//            state <= E_A24;
//        end
 
//        E_A24: if (mul_done) begin
//            Z3     <= mul_res;                                        // Z3
//            X3_inf <= 1'b0;
//            busy   <= 1'b0;
//            done   <= 1'b1;
//            state  <= E_IDLE;
//        end
 
//        default: state <= E_IDLE;
 
//        endcase
//    end
//end
 
//endmodule


//`timescale 1ns/1ps
////======================================================================
//// ecc_point_engine_256   (adds a shared-ALU passthrough for the
//// inverter, on top of the already-shared multiplier passthrough)
////======================================================================
//module ecc_point_engine_256 #(
//    parameter WIDTH = 256,
//    parameter P =
//    256'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
//)(
//    input clk,
//    input rst,

//    input start,
//    input op,               // 0 = DOUBLE (uses X1,Y1,Z1,X1_inf only)
//                             // 1 = ADD    (X1,Y1,Z1,X1_inf + X2,Y2,Z2,X2_inf)

//    input [WIDTH-1:0] X1,
//    input [WIDTH-1:0] Y1,
//    input [WIDTH-1:0] Z1,
//    input             X1_inf,

//    input [WIDTH-1:0] X2,
//    input [WIDTH-1:0] Y2,
//    input [WIDTH-1:0] Z2,
//    input             X2_inf,

//    output reg [WIDTH-1:0] X3,
//    output reg [WIDTH-1:0] Y3,
//    output reg [WIDTH-1:0] Z3,
//    output reg              X3_inf,

//    output reg done,
//    output reg busy,

//    // ------------------------------------------------------------
//    // Shared-multiplier passthrough (unchanged): lets the top level
//    // reuse THIS single multiplier instance for final-coordinate
//    // normalization instead of instantiating a separate one. Only
//    // usable while the engine is idle (busy == 0).
//    // ------------------------------------------------------------
//    input                    ext_start,
//    input      [WIDTH-1:0]   ext_a,
//    input      [WIDTH-1:0]   ext_b,
//    output reg [WIDTH-1:0]   ext_res,
//    output reg               ext_done,

//    // ------------------------------------------------------------
//    // Shared-ALU passthrough (NEW): same idea as ext_* above, but for
//    // the add/sub ALU. mod_inv_bin_256 used to own a second, otherwise
//    // identical mod_addsub_256 instance purely because it had no way
//    // to reach this one. It only ever runs while this engine is idle
//    // (the top-level FSM starts the inverter only after the ladder is
//    // done), so it can share this ALU instead of duplicating it.
//    // ------------------------------------------------------------
//    input                    alu_ext_start,
//    input      [WIDTH-1:0]   alu_ext_a,
//    input      [WIDTH-1:0]   alu_ext_b,
//    input                    alu_ext_sub,
//    output reg [WIDTH-1:0]   alu_ext_res,
//    output reg               alu_ext_done
//);

////--------------------------------------------------
//// Single shared multiplier (unchanged - already one instance)
////--------------------------------------------------
//reg  [WIDTH-1:0] ma, mb;
//reg              mul_start;
//wire [WIDTH-1:0] mul_res;
//wire             mul_done;
//wire             mul_busy;

//mod_mult_iter_256 #(WIDTH,P) U_MUL (
//    .clk(clk), .rst(rst),
//    .start(mul_start),
//    .a(ma), .b(mb),
//    .res(mul_res), .done(mul_done), .busy(mul_busy)
//);

////--------------------------------------------------
//// Single shared modular add/sub ALU (still exactly ONE instance in
//// the whole design now - the inverter no longer has its own)
////--------------------------------------------------
//reg  [WIDTH-1:0] alu_a, alu_b;
//reg              alu_sub;
//wire [WIDTH-1:0] alu_y;

//mod_addsub_256 #(WIDTH,P) U_ALU (
//    .x(alu_a), .y(alu_b), .sub(alu_sub), .res(alu_y)
//);

////--------------------------------------------------
//// Shared scratch pool - reused by BOTH the doubling flow and the
//// addition flow (they never run at the same time)
////--------------------------------------------------
//reg [WIDTH-1:0] t0, t1, t2, t3, t4, t5, t6, t7, t8, t9, t10, t11, t12;

////--------------------------------------------------
//// States
////--------------------------------------------------
//localparam
//    E_IDLE      = 0,
//    E_EXT_W     = 1,

//    // ---- doubling flow (also reused for the add-collision case) ----
//    E_D_ENTRY   = 2,
//    E_D1        = 3,   // capture YY,           dispatch XYY  mul
//    E_D2        = 4,   // capture XYY,          dispatch 2*XYY alu
//    E_D3        = 5,   // capture 2*XYY,        dispatch 4*XYY alu
//    E_D4        = 6,   // capture S=4*XYY,      dispatch XX   mul
//    E_D5        = 7,   // capture XX,           dispatch 2*XX alu
//    E_D6        = 8,   // capture 2*XX(Mt),     dispatch Mt+XX alu
//    E_D7        = 9,   // capture M=3*XX,       dispatch M*M  mul
//    E_D8        = 10,  // capture M2,           dispatch 2*S  alu
//    E_D9        = 11,  // capture S2=2*S,       dispatch M2-S2 alu
//    E_D10       = 12,  // capture X3=M2-S2,     dispatch S-X3  alu
//    E_D11       = 13,  // capture SX3=S-X3,     dispatch M*SX3 mul
//    E_D12       = 14,  // capture T=M*SX3,      dispatch YY*YY mul
//    E_D13       = 15,  // capture YY2,          dispatch 2*YY2 alu
//    E_D14       = 16,  // capture 2*YY2,        dispatch 4*YY2 alu
//    E_D15       = 17,  // capture 4*YY2,        dispatch 8*YY2 alu
//    E_D16       = 18,  // capture YY8=8*YY2,    dispatch T-YY8 alu
//    E_D17       = 19,  // capture Y3=T-YY8,     dispatch Y1*Z1 mul
//    E_D18       = 20,  // capture Z3raw,        dispatch 2*Z3raw alu
//    E_D19       = 21,  // capture Z3=2*Z3raw,   done

//    // ---- addition flow (add-2007-bl) ----
//    E_A_ENTRY   = 30,
//    E_A1        = 31,  // dispatch Z1*Z1 mul
//    E_A2        = 32,  // capture Z1Z1,   dispatch Z2*Z2 mul
//    E_A3        = 33,  // capture Z2Z2,   dispatch X1*Z2Z2 mul (U1)
//    E_A4        = 34,  // capture U1,     dispatch X2*Z1Z1 mul (U2)
//    E_A5        = 35,  // capture U2,     dispatch Z1*Z1Z1 mul (Z1CUBE)
//    E_A6        = 36,  // capture Z1CUBE, dispatch Z2*Z2Z2 mul (Z2CUBE)
//    E_A7        = 37,  // capture Z2CUBE, dispatch Y1*Z2CUBE mul (S1)
//    E_A8        = 38,  // capture S1,     dispatch Y2*Z1CUBE mul (S2)
//    E_A9        = 39,  // capture S2,     dispatch U2-U1 alu (H)
//    E_A10       = 40,  // capture H,      dispatch S2-S1 alu (R)
//    E_A11       = 41,  // capture R, decide collision / infinity / continue
//    E_A12       = 42,  // capture H*H(HH) started at A11-else, wait mul
//    E_A13       = 43,  // capture HH,     dispatch H*HH mul (HHH)
//    E_A14       = 44,  // capture HHH,    dispatch U1*HH mul (V)
//    E_A15       = 45,  // capture V,      dispatch R*R  mul (R2)
//    E_A16       = 46,  // capture R2, dispatch R2-HHH alu (X3_tmp)
//    E_A17       = 47,  // capture X3_tmp, dispatch 2*V alu (V2)
//    E_A18       = 48,  // capture V2,     dispatch X3_tmp-V2 alu (X3)
//    E_A19       = 49,  // capture X3,     dispatch V-X3 alu (VX3)
//    E_A20       = 50,  // capture VX3,    dispatch R*VX3 mul (RVX)
//    E_A21       = 51,  // capture RVX,    dispatch S1*HHH mul (S1HHH)
//    E_A22       = 52,  // capture S1HHH,  dispatch RVX-S1HHH alu (Y3)
//    E_A23       = 53,  // capture Y3,     dispatch H*Z1 mul (Z3a)
//    E_A24       = 54,  // capture Z3a,    dispatch Z3a*Z2 mul (Z3)
//    E_A25       = 55,  // capture Z3, done

//    E_EXT_ALU_W = 62,  // NEW: servicing an external ALU request

//    E_DONE      = 63;

//reg [7:0] state;

//always @(posedge clk) begin

//    if (rst) begin

//        state     <= E_IDLE;
//        busy      <= 1'b0;
//        done      <= 1'b0;
//        mul_start <= 1'b0;

//        alu_a <= 0; alu_b <= 0; alu_sub <= 1'b0;
//        ma <= 0; mb <= 0;

//        t0<=0; t1<=0; t2<=0; t3<=0; t4<=0; t5<=0; t6<=0;
//        t7<=0; t8<=0; t9<=0; t10<=0; t11<=0; t12<=0;

//        X3 <= 0; Y3 <= 0; Z3 <= 0; X3_inf <= 1'b0;

//        ext_res  <= 0;
//        ext_done <= 1'b0;

//        alu_ext_res  <= 0;
//        alu_ext_done <= 1'b0;

//    end else begin

//        done      <= 1'b0;
//        mul_start <= 1'b0;
//        ext_done  <= 1'b0;
//        alu_ext_done <= 1'b0;

//        case (state)

//        //==================================================
//        // IDLE / dispatch
//        //==================================================
//        E_IDLE: begin
//            if (start && !busy) begin
//                busy <= 1'b1;
//                if (op == 1'b0)
//                    state <= E_D_ENTRY;
//                else
//                    state <= E_A_ENTRY;
//            end
//            else if (ext_start) begin
//                busy      <= 1'b1;
//                ma        <= ext_a;
//                mb        <= ext_b;
//                mul_start <= 1'b1;
//                state     <= E_EXT_W;
//            end
//            else if (alu_ext_start) begin
//                busy    <= 1'b1;
//                alu_a   <= alu_ext_a;
//                alu_b   <= alu_ext_b;
//                alu_sub <= alu_ext_sub;
//                state   <= E_EXT_ALU_W;
//            end
//        end

//        E_EXT_W: begin
//            if (mul_done) begin
//                ext_res  <= mul_res;
//                ext_done <= 1'b1;
//                busy     <= 1'b0;
//                state    <= E_IDLE;
//            end
//        end

//        // alu_a/alu_b/alu_sub were registered on the edge that
//        // brought us here, so alu_y (combinational) is already valid
//        // this cycle - one-cycle turnaround, same pattern used
//        // throughout the doubling/addition flows below.
//        E_EXT_ALU_W: begin
//            alu_ext_res  <= alu_y;
//            alu_ext_done <= 1'b1;
//            busy         <= 1'b0;
//            state        <= E_IDLE;
//        end

//        //==================================================
//        // DOUBLING FLOW  (dbl-2009-l, a = 0)
//        //   YY  = Y1^2
//        //   S   = 4*X1*YY
//        //   M   = 3*X1^2
//        //   M2  = M^2
//        //   X3  = M2 - 2S
//        //   T   = M*(S - X3)
//        //   YY2 = YY^2
//        //   Y3  = T - 8*YY2
//        //   Z3  = 2*Y1*Z1
//        //==================================================
//        E_D_ENTRY: begin
//            if (X1_inf || (Y1 == 0)) begin
//                X3 <= 0; Y3 <= 1; Z3 <= 0; X3_inf <= 1'b1;
//                busy <= 1'b0; done <= 1'b1;
//                state <= E_IDLE;
//            end else begin
//                ma <= Y1; mb <= Y1; mul_start <= 1'b1;   // YY = Y1*Y1
//                state <= E_D1;
//            end
//        end

//        E_D1: if (mul_done) begin
//            t0 <= mul_res;                                // YY
//            ma <= X1; mb <= mul_res; mul_start <= 1'b1;    // XYY = X1*YY
//            state <= E_D2;
//        end

//        E_D2: if (mul_done) begin
//            t1 <= mul_res;                                 // XYY
//            alu_a <= mul_res; alu_b <= mul_res; alu_sub <= 1'b0;  // 2*XYY
//            state <= E_D3;
//        end

//        E_D3: begin
//            t2 <= alu_y;                                    // 2*XYY
//            alu_a <= alu_y; alu_b <= alu_y; alu_sub <= 1'b0; // 4*XYY
//            state <= E_D4;
//        end

//        E_D4: begin
//            t2 <= alu_y;                                     // S = 4*XYY
//            ma <= X1; mb <= X1; mul_start <= 1'b1;            // XX = X1*X1
//            state <= E_D5;
//        end

//        E_D5: if (mul_done) begin
//            t3 <= mul_res;                                    // XX
//            alu_a <= mul_res; alu_b <= mul_res; alu_sub <= 1'b0; // 2*XX
//            state <= E_D6;
//        end

//        E_D6: begin
//            t4 <= alu_y;                                      // Mt = 2*XX
//            alu_a <= alu_y; alu_b <= t3; alu_sub <= 1'b0;      // M = Mt+XX
//            state <= E_D7;
//        end

//        E_D7: begin
//            t4 <= alu_y;                                      // M = 3*XX
//            ma <= alu_y; mb <= alu_y; mul_start <= 1'b1;       // M2 = M*M
//            state <= E_D8;
//        end

//        E_D8: if (mul_done) begin
//            t5 <= mul_res;                                    // M2
//            alu_a <= t2; alu_b <= t2; alu_sub <= 1'b0;         // S2 = 2*S
//            state <= E_D9;
//        end

//        E_D9: begin
//            t6 <= alu_y;                                       // S2
//            alu_a <= t5; alu_b <= alu_y; alu_sub <= 1'b1;       // X3=M2-S2
//            state <= E_D10;
//        end

//        E_D10: begin
//            X3 <= alu_y;                                        // X3
//            alu_a <= t2; alu_b <= alu_y; alu_sub <= 1'b1;        // SX3=S-X3
//            state <= E_D11;
//        end

//        E_D11: begin
//            t8 <= alu_y;                                         // SX3
//            ma <= t4; mb <= alu_y; mul_start <= 1'b1;             // T=M*SX3
//            state <= E_D12;
//        end

//        E_D12: if (mul_done) begin
//            t9 <= mul_res;                                       // T
//            ma <= t0; mb <= t0; mul_start <= 1'b1;                // YY2=YY*YY
//            state <= E_D13;
//        end

//        E_D13: if (mul_done) begin
//            t10 <= mul_res;                                      // YY2
//            alu_a <= mul_res; alu_b <= mul_res; alu_sub <= 1'b0;  // 2*YY2
//            state <= E_D14;
//        end

//        E_D14: begin
//            t11 <= alu_y;                                         // 2*YY2
//            alu_a <= alu_y; alu_b <= alu_y; alu_sub <= 1'b0;       // 4*YY2
//            state <= E_D15;
//        end

//        E_D15: begin
//            t11 <= alu_y;                                          // 4*YY2
//            alu_a <= alu_y; alu_b <= alu_y; alu_sub <= 1'b0;        // 8*YY2
//            state <= E_D16;
//        end

//        E_D16: begin
//            t11 <= alu_y;                                          // YY8
//            alu_a <= t9; alu_b <= alu_y; alu_sub <= 1'b1;           // T-YY8
//            state <= E_D17;
//        end

//        E_D17: begin
//            Y3 <= alu_y;                                           // Y3
//            ma <= Y1; mb <= Z1; mul_start <= 1'b1;                  // Y1*Z1
//            state <= E_D18;
//        end

//        E_D18: if (mul_done) begin
//            t12 <= mul_res;                                        // Z3raw
//            alu_a <= mul_res; alu_b <= mul_res; alu_sub <= 1'b0;    // 2*Z3raw
//            state <= E_D19;
//        end

//        E_D19: begin
//            Z3     <= alu_y;                                       // Z3
//            X3_inf <= 1'b0;
//            busy   <= 1'b0;
//            done   <= 1'b1;
//            state  <= E_IDLE;
//        end

//        //==================================================
//        // ADDITION FLOW  (Jacobian general addition, add-2007-bl)
//        //==================================================
//        E_A_ENTRY: begin
//            if (X1_inf) begin
//                X3 <= X2; Y3 <= Y2; Z3 <= Z2; X3_inf <= X2_inf;
//                busy <= 1'b0; done <= 1'b1; state <= E_IDLE;
//            end else if (X2_inf) begin
//                X3 <= X1; Y3 <= Y1; Z3 <= Z1; X3_inf <= X1_inf;
//                busy <= 1'b0; done <= 1'b1; state <= E_IDLE;
//            end else begin
//                ma <= Z1; mb <= Z1; mul_start <= 1'b1;              // Z1Z1
//                state <= E_A1;
//            end
//        end

//        E_A1: if (mul_done) begin
//            t0 <= mul_res;                                          // Z1Z1
//            ma <= Z2; mb <= Z2; mul_start <= 1'b1;                  // Z2Z2
//            state <= E_A2;
//        end

//        E_A2: if (mul_done) begin
//            t1 <= mul_res;                                          // Z2Z2
//            ma <= X1; mb <= mul_res; mul_start <= 1'b1;              // U1
//            state <= E_A3;
//        end

//        E_A3: if (mul_done) begin
//            t2 <= mul_res;                                          // U1
//            ma <= X2; mb <= t0; mul_start <= 1'b1;                   // U2
//            state <= E_A4;
//        end

//        E_A4: if (mul_done) begin
//            t3 <= mul_res;                                          // U2
//            ma <= Z1; mb <= t0; mul_start <= 1'b1;                   // Z1CUBE
//            state <= E_A5;
//        end

//        E_A5: if (mul_done) begin
//            t4 <= mul_res;                                          // Z1CUBE
//            ma <= Z2; mb <= t1; mul_start <= 1'b1;                   // Z2CUBE
//            state <= E_A6;
//        end

//        E_A6: if (mul_done) begin
//            t5 <= mul_res;                                          // Z2CUBE
//            ma <= Y1; mb <= mul_res; mul_start <= 1'b1;              // S1
//            state <= E_A7;
//        end

//        E_A7: if (mul_done) begin
//            t6 <= mul_res;                                          // S1
//            ma <= Y2; mb <= t4; mul_start <= 1'b1;                   // S2
//            state <= E_A8;
//        end

//        E_A8: if (mul_done) begin
//            t7 <= mul_res;                                          // S2
//            alu_a <= t3; alu_b <= t2; alu_sub <= 1'b1;                // H=U2-U1
//            state <= E_A9;
//        end

//        E_A9: begin
//            t8 <= alu_y;                                             // H
//            alu_a <= t7; alu_b <= t6; alu_sub <= 1'b1;                // R=S2-S1
//            state <= E_A10;
//        end

//        E_A10: begin
//            t9 <= alu_y;
//            state <= E_A11;
//        end

//        E_A11: begin
//            if (t8 == 0) begin
//                if (t9 == 0) begin
//                    // P1 == P2 : fall through into the SAME doubling
//                    // datapath used above - no second doubler needed.
//                    state <= E_D_ENTRY;
//                end else begin
//                    X3 <= 0; Y3 <= 1; Z3 <= 0; X3_inf <= 1'b1;
//                    busy <= 1'b0; done <= 1'b1; state <= E_IDLE;
//                end
//            end else begin
//                ma <= t8; mb <= t8; mul_start <= 1'b1;                // HH=H*H
//                state <= E_A12;
//            end
//        end

//        E_A12: if (mul_done) begin
//            t10 <= mul_res;                                          // HH
//            ma <= t8; mb <= mul_res; mul_start <= 1'b1;               // HHH
//            state <= E_A13;
//        end

//        E_A13: if (mul_done) begin
//            t11 <= mul_res;                                          // HHH
//            ma <= t2; mb <= t10; mul_start <= 1'b1;                   // V=U1*HH
//            state <= E_A14;
//        end

//        E_A14: if (mul_done) begin
//            t12 <= mul_res;                                          // V
//            ma <= t9; mb <= t9; mul_start <= 1'b1;                    // R2=R*R
//            state <= E_A15;
//        end

//        E_A15: if (mul_done) begin
//            alu_a <= mul_res; alu_b <= t11; alu_sub <= 1'b1;          // R2-HHH
//            state <= E_A16;
//        end

//        E_A16: begin
//            t0 <= alu_y;                                              // X3_tmp
//            alu_a <= t12; alu_b <= t12; alu_sub <= 1'b0;               // 2*V
//            state <= E_A17;
//        end

//        E_A17: begin
//            t1 <= alu_y;                                              // V2
//            alu_a <= t0; alu_b <= alu_y; alu_sub <= 1'b1;              // X3
//            state <= E_A18;
//        end

//        E_A18: begin
//            X3 <= alu_y;                                              // X3
//            alu_a <= t12; alu_b <= alu_y; alu_sub <= 1'b1;             // V-X3
//            state <= E_A19;
//        end

//        E_A19: begin
//            t2 <= alu_y;                                              // VX3
//            ma <= t9; mb <= alu_y; mul_start <= 1'b1;                  // R*VX3
//            state <= E_A20;
//        end

//        E_A20: if (mul_done) begin
//            t3 <= mul_res;                                            // RVX
//            ma <= t6; mb <= t11; mul_start <= 1'b1;                    // S1*HHH
//            state <= E_A21;
//        end

//        E_A21: if (mul_done) begin
//            t4 <= mul_res;                                            // S1HHH
//            alu_a <= t3; alu_b <= mul_res; alu_sub <= 1'b1;            // Y3
//            state <= E_A22;
//        end

//        E_A22: begin
//            Y3 <= alu_y;                                              // Y3
//            ma <= t8; mb <= Z1; mul_start <= 1'b1;                     // H*Z1
//            state <= E_A23;
//        end

//        E_A23: if (mul_done) begin
//            t0 <= mul_res;                                            // Z3a
//            ma <= mul_res; mb <= Z2; mul_start <= 1'b1;                 // Z3a*Z2
//            state <= E_A24;
//        end

//        E_A24: if (mul_done) begin
//            Z3     <= mul_res;                                        // Z3
//            X3_inf <= 1'b0;
//            busy   <= 1'b0;
//            done   <= 1'b1;
//            state  <= E_IDLE;
//        end

//        default: state <= E_IDLE;

//        endcase
//    end
//end

//endmodule

`timescale 1ns/1ps
`default_nettype wire
//======================================================================
// ecc_point_engine_256
//
// Port list, module name and parameters are UNCHANGED, so top.v needs
// no edits and tb_ecc_func_80.v (which only ever touches the
// top-level DUT) keeps working with zero edits.
//
// HISTORY OF CHANGES (all verified bit-exact against
// tb_ecc_func_80.v at each step):
//   1. Single shared mod_mult_iter_256 instance instead of ~30 inlined
//      multiply call sites.
//   2. Single shared mod_addsub_256 instance instead of ~30 inlined
//      add/sub call sites; 13-register shared scratch pool t0..t12
//      reused by both the doubling flow and the addition flow (they
//      never run concurrently).
//   3. mod_inv_bin_256 (the modular inverter) no longer owns its own
//      second mod_addsub_256 instance - it shares THIS one via the
//      alu_ext_* passthrough below, the same idea as the ext_*
//      multiplier passthrough that already existed for
//      final-coordinate normalization.
//   4. mod_addsub_256 and mod_mult_iter_256 were converted from full
//      257-bit-wide combinational arithmetic to word-serial (129-bit
//      chunk, 2 chunks) clocked arithmetic, to cut LUT usage - trading
//      more clock cycles per operation for much less hardware. Every
//      ALU dispatch site below now does a start/wait-for-done
//      handshake with the ALU instead of an instant 1-cycle
//      combinational read, exactly the same pattern already used for
//      the multiplier throughout this file.
//
// The underlying math is untouched: dbl-2009-l (a=0 curve) for
// doubling, add-2007-bl for general addition - results are bit-for-
// bit identical to the functionally-verified design at every step
// above.
//======================================================================
module ecc_point_engine_256 #(
    parameter WIDTH = 256,
    parameter P =
    256'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
)(
    input clk,
    input rst,
 
    input start,
    input op,               // 0 = DOUBLE (uses X1,Y1,Z1,X1_inf only)
                             // 1 = ADD    (X1,Y1,Z1,X1_inf + X2,Y2,Z2,X2_inf)
 
    input [WIDTH-1:0] X1,
    input [WIDTH-1:0] Y1,
    input [WIDTH-1:0] Z1,
    input             X1_inf,
 
    input [WIDTH-1:0] X2,
    input [WIDTH-1:0] Y2,
    input [WIDTH-1:0] Z2,
    input             X2_inf,
 
    output reg [WIDTH-1:0] X3,
    output reg [WIDTH-1:0] Y3,
    output reg [WIDTH-1:0] Z3,
    output reg              X3_inf,
 
    output reg done,
    output reg busy,
 
    // ------------------------------------------------------------
    // Shared-multiplier passthrough: lets the top level reuse THIS
    // single multiplier instance for final-coordinate normalization.
    // Only usable while the engine is idle (busy == 0); the top-level
    // FSM only ever drives this after the Montgomery ladder has
    // finished, so there is no contention in practice.
    // ------------------------------------------------------------
    input                    ext_start,
    input      [WIDTH-1:0]   ext_a,
    input      [WIDTH-1:0]   ext_b,
    output reg [WIDTH-1:0]   ext_res,
    output reg               ext_done,
 
    // ------------------------------------------------------------
    // Shared-ALU passthrough: same idea as ext_* above, but for the
    // add/sub ALU. mod_inv_bin_256 shares THIS instance instead of
    // owning its own; it only ever runs while this engine is idle.
    // ------------------------------------------------------------
    input                    alu_ext_start,
    input      [WIDTH-1:0]   alu_ext_a,
    input      [WIDTH-1:0]   alu_ext_b,
    input                    alu_ext_sub,
    output reg [WIDTH-1:0]   alu_ext_res,
    output reg               alu_ext_done
);
 
//--------------------------------------------------
// Single shared multiplier (word-serial, clocked)
//--------------------------------------------------
reg  [WIDTH-1:0] ma, mb;
reg              mul_start;
wire [WIDTH-1:0] mul_res;
wire             mul_done;
wire             mul_busy;
 
mod_mult_iter_256 #(WIDTH,P) U_MUL (
    .clk(clk), .rst(rst),
    .start(mul_start),
    .a(ma), .b(mb),
    .res(mul_res), .done(mul_done), .busy(mul_busy)
);
 
//--------------------------------------------------
// Single shared modular add/sub ALU (word-serial, clocked - dispatch
// with alu_start, wait for alu_done, then read alu_y, exactly the
// same pattern as the multiplier above)
//--------------------------------------------------
reg  [WIDTH-1:0] alu_a, alu_b;
reg              alu_sub;
reg              alu_start;
wire [WIDTH-1:0] alu_y;
wire             alu_done;
wire             alu_busy;
 
mod_addsub_256 #(WIDTH,P) U_ALU (
    .clk(clk), .rst(rst),
    .start(alu_start),
    .x(alu_a), .y(alu_b), .sub(alu_sub),
    .res(alu_y), .done(alu_done), .busy(alu_busy)
);
 
//--------------------------------------------------
// Shared scratch pool - reused by BOTH the doubling flow and the
// addition flow (they never run at the same time)
//--------------------------------------------------
reg [WIDTH-1:0] t0, t1, t2, t3, t4, t5, t6, t7, t8, t9, t10, t11, t12;
 
//--------------------------------------------------
// States
//--------------------------------------------------
localparam
    E_IDLE      = 0,
    E_EXT_W     = 1,
 
    // ---- doubling flow (also reused for the add-collision case) ----
    E_D_ENTRY   = 2,
    E_D1        = 3,   // capture YY,           dispatch XYY  mul
    E_D2        = 4,   // capture XYY,          dispatch 2*XYY alu
    E_D3        = 5,   // capture 2*XYY,        dispatch 4*XYY alu
    E_D4        = 6,   // capture S=4*XYY,      dispatch XX   mul
    E_D5        = 7,   // capture XX,           dispatch 2*XX alu
    E_D6        = 8,   // capture 2*XX(Mt),     dispatch Mt+XX alu
    E_D7        = 9,   // capture M=3*XX,       dispatch M*M  mul
    E_D8        = 10,  // capture M2,           dispatch 2*S  alu
    E_D9        = 11,  // capture S2=2*S,       dispatch M2-S2 alu
    E_D10       = 12,  // capture X3=M2-S2,     dispatch S-X3  alu
    E_D11       = 13,  // capture SX3=S-X3,     dispatch M*SX3 mul
    E_D12       = 14,  // capture T=M*SX3,      dispatch YY*YY mul
    E_D13       = 15,  // capture YY2,          dispatch 2*YY2 alu
    E_D14       = 16,  // capture 2*YY2,        dispatch 4*YY2 alu
    E_D15       = 17,  // capture 4*YY2,        dispatch 8*YY2 alu
    E_D16       = 18,  // capture YY8=8*YY2,    dispatch T-YY8 alu
    E_D17       = 19,  // capture Y3=T-YY8,     dispatch Y1*Z1 mul
    E_D18       = 20,  // capture Z3raw,        dispatch 2*Z3raw alu
    E_D19       = 21,  // capture Z3=2*Z3raw,   done
 
    // ---- addition flow (add-2007-bl) ----
    E_A_ENTRY   = 30,
    E_A1        = 31,  // dispatch Z1*Z1 mul
    E_A2        = 32,  // capture Z1Z1,   dispatch Z2*Z2 mul
    E_A3        = 33,  // capture Z2Z2,   dispatch X1*Z2Z2 mul (U1)
    E_A4        = 34,  // capture U1,     dispatch X2*Z1Z1 mul (U2)
    E_A5        = 35,  // capture U2,     dispatch Z1*Z1Z1 mul (Z1CUBE)
    E_A6        = 36,  // capture Z1CUBE, dispatch Z2*Z2Z2 mul (Z2CUBE)
    E_A7        = 37,  // capture Z2CUBE, dispatch Y1*Z2CUBE mul (S1)
    E_A8        = 38,  // capture S1,     dispatch Y2*Z1CUBE mul (S2)
    E_A9        = 39,  // capture S2,     dispatch U2-U1 alu (H)
    E_A10       = 40,  // capture H,      dispatch S2-S1 alu (R)
    E_A11       = 41,  // capture R, decide collision / infinity / continue
    E_A12       = 42,  // capture H*H(HH) started at A11-else, wait mul
    E_A13       = 43,  // capture HH,     dispatch H*HH mul (HHH)
    E_A14       = 44,  // capture HHH,    dispatch U1*HH mul (V)
    E_A15       = 45,  // capture V,      dispatch R*R  mul (R2)
    E_A16       = 46,  // capture R2, dispatch R2-HHH alu (X3_tmp)
    E_A17       = 47,  // capture X3_tmp, dispatch 2*V alu (V2)
    E_A18       = 48,  // capture V2,     dispatch X3_tmp-V2 alu (X3)
    E_A19       = 49,  // capture X3,     dispatch V-X3 alu (VX3)
    E_A20       = 50,  // capture VX3,    dispatch R*VX3 mul (RVX)
    E_A21       = 51,  // capture RVX,    dispatch S1*HHH mul (S1HHH)
    E_A22       = 52,  // capture S1HHH,  dispatch RVX-S1HHH alu (Y3)
    E_A23       = 53,  // capture Y3,     dispatch H*Z1 mul (Z3a)
    E_A24       = 54,  // capture Z3a,    dispatch Z3a*Z2 mul (Z3)
    E_A25       = 55,  // capture Z3, done
 
    E_EXT_ALU_W = 62,  // servicing an external ALU request (invbin.v)
 
    E_DONE      = 63;
 
reg [7:0] state;
 
always @(posedge clk) begin
 
    if (rst) begin
 
        state     <= E_IDLE;
        busy      <= 1'b0;
        done      <= 1'b0;
        mul_start <= 1'b0;
 
        alu_a <= 0; alu_b <= 0; alu_sub <= 1'b0; alu_start <= 1'b0;
        ma <= 0; mb <= 0;
 
        t0<=0; t1<=0; t2<=0; t3<=0; t4<=0; t5<=0; t6<=0;
        t7<=0; t8<=0; t9<=0; t10<=0; t11<=0; t12<=0;
 
        X3 <= 0; Y3 <= 0; Z3 <= 0; X3_inf <= 1'b0;
 
        ext_res  <= 0;
        ext_done <= 1'b0;
 
        alu_ext_res  <= 0;
        alu_ext_done <= 1'b0;
 
    end else begin
 
        done      <= 1'b0;
        mul_start <= 1'b0;
        ext_done  <= 1'b0;
        alu_start <= 1'b0;
        alu_ext_done <= 1'b0;
 
        case (state)
 
        //==================================================
        // IDLE / dispatch
        //==================================================
        E_IDLE: begin
            if (start && !busy) begin
                busy <= 1'b1;
                if (op == 1'b0)
                    state <= E_D_ENTRY;
                else
                    state <= E_A_ENTRY;
            end
            else if (ext_start) begin
                busy      <= 1'b1;
                ma        <= ext_a;
                mb        <= ext_b;
                mul_start <= 1'b1;
                state     <= E_EXT_W;
            end
            else if (alu_ext_start) begin
                busy      <= 1'b1;
                alu_a     <= alu_ext_a;
                alu_b     <= alu_ext_b;
                alu_sub   <= alu_ext_sub;
                alu_start <= 1'b1;
                state     <= E_EXT_ALU_W;
            end
        end
 
        E_EXT_W: begin
            if (mul_done) begin
                ext_res  <= mul_res;
                ext_done <= 1'b1;
                busy     <= 1'b0;
                state    <= E_IDLE;
            end
        end
 
        E_EXT_ALU_W: begin
            if (alu_done) begin
                alu_ext_res  <= alu_y;
                alu_ext_done <= 1'b1;
                busy         <= 1'b0;
                state        <= E_IDLE;
            end
        end
 
        //==================================================
        // DOUBLING FLOW  (dbl-2009-l, a = 0)
        //   YY  = Y1^2
        //   S   = 4*X1*YY
        //   M   = 3*X1^2
        //   M2  = M^2
        //   X3  = M2 - 2S
        //   T   = M*(S - X3)
        //   YY2 = YY^2
        //   Y3  = T - 8*YY2
        //   Z3  = 2*Y1*Z1
        //==================================================
        E_D_ENTRY: begin
            if (X1_inf || (Y1 == 0)) begin
                X3 <= 0; Y3 <= 1; Z3 <= 0; X3_inf <= 1'b1;
                busy <= 1'b0; done <= 1'b1;
                state <= E_IDLE;
            end else begin
                ma <= Y1; mb <= Y1; mul_start <= 1'b1;   // YY = Y1*Y1
                state <= E_D1;
            end
        end
 
        E_D1: if (mul_done) begin
            t0 <= mul_res;                                // YY
            ma <= X1; mb <= mul_res; mul_start <= 1'b1;    // XYY = X1*YY
            state <= E_D2;
        end
 
        E_D2: if (mul_done) begin
            t1 <= mul_res;                                         // XYY
            alu_a <= mul_res; alu_b <= mul_res; alu_sub <= 1'b0;    // 2*XYY
            alu_start <= 1'b1;
            state <= E_D3;
        end
 
        E_D3: if (alu_done) begin
            t2 <= alu_y;                                            // 2*XYY
            alu_a <= alu_y; alu_b <= alu_y; alu_sub <= 1'b0;         // 4*XYY
            alu_start <= 1'b1;
            state <= E_D4;
        end
 
        E_D4: if (alu_done) begin
            t2 <= alu_y;                                     // S = 4*XYY
            ma <= X1; mb <= X1; mul_start <= 1'b1;            // XX = X1*X1
            state <= E_D5;
        end
 
        E_D5: if (mul_done) begin
            t3 <= mul_res;                                          // XX
            alu_a <= mul_res; alu_b <= mul_res; alu_sub <= 1'b0;     // 2*XX
            alu_start <= 1'b1;
            state <= E_D6;
        end
 
        E_D6: if (alu_done) begin
            t4 <= alu_y;                                      // Mt = 2*XX
            alu_a <= alu_y; alu_b <= t3; alu_sub <= 1'b0;      // M = Mt+XX
            alu_start <= 1'b1;
            state <= E_D7;
        end
 
        E_D7: if (alu_done) begin
            t4 <= alu_y;                                      // M = 3*XX
            ma <= alu_y; mb <= alu_y; mul_start <= 1'b1;       // M2 = M*M
            state <= E_D8;
        end
 
        E_D8: if (mul_done) begin
            t5 <= mul_res;                                     // M2
            alu_a <= t2; alu_b <= t2; alu_sub <= 1'b0;          // S2 = 2*S
            alu_start <= 1'b1;
            state <= E_D9;
        end
 
        E_D9: if (alu_done) begin
            t6 <= alu_y;                                        // S2
            alu_a <= t5; alu_b <= alu_y; alu_sub <= 1'b1;        // X3=M2-S2
            alu_start <= 1'b1;
            state <= E_D10;
        end
 
        E_D10: if (alu_done) begin
            X3 <= alu_y;                                         // X3
            alu_a <= t2; alu_b <= alu_y; alu_sub <= 1'b1;         // SX3=S-X3
            alu_start <= 1'b1;
            state <= E_D11;
        end
 
        E_D11: if (alu_done) begin
            t8 <= alu_y;                                          // SX3
            ma <= t4; mb <= alu_y; mul_start <= 1'b1;              // T=M*SX3
            state <= E_D12;
        end
 
        E_D12: if (mul_done) begin
            t9 <= mul_res;                                       // T
            ma <= t0; mb <= t0; mul_start <= 1'b1;                // YY2=YY*YY
            state <= E_D13;
        end
 
        E_D13: if (mul_done) begin
            t10 <= mul_res;                                        // YY2
            alu_a <= mul_res; alu_b <= mul_res; alu_sub <= 1'b0;    // 2*YY2
            alu_start <= 1'b1;
            state <= E_D14;
        end
 
        E_D14: if (alu_done) begin
            t11 <= alu_y;                                           // 2*YY2
            alu_a <= alu_y; alu_b <= alu_y; alu_sub <= 1'b0;         // 4*YY2
            alu_start <= 1'b1;
            state <= E_D15;
        end
 
        E_D15: if (alu_done) begin
            t11 <= alu_y;                                           // 4*YY2
            alu_a <= alu_y; alu_b <= alu_y; alu_sub <= 1'b0;         // 8*YY2
            alu_start <= 1'b1;
            state <= E_D16;
        end
 
        E_D16: if (alu_done) begin
            t11 <= alu_y;                                           // YY8
            alu_a <= t9; alu_b <= alu_y; alu_sub <= 1'b1;            // T-YY8
            alu_start <= 1'b1;
            state <= E_D17;
        end
 
        E_D17: if (alu_done) begin
            Y3 <= alu_y;                                            // Y3
            ma <= Y1; mb <= Z1; mul_start <= 1'b1;                   // Y1*Z1
            state <= E_D18;
        end
 
        E_D18: if (mul_done) begin
            t12 <= mul_res;                                          // Z3raw
            alu_a <= mul_res; alu_b <= mul_res; alu_sub <= 1'b0;      // 2*Z3raw
            alu_start <= 1'b1;
            state <= E_D19;
        end
 
        E_D19: if (alu_done) begin
            Z3     <= alu_y;                                       // Z3
            X3_inf <= 1'b0;
            busy   <= 1'b0;
            done   <= 1'b1;
            state  <= E_IDLE;
        end
 
        //==================================================
        // ADDITION FLOW  (Jacobian general addition, add-2007-bl)
        //==================================================
        E_A_ENTRY: begin
            if (X1_inf) begin
                X3 <= X2; Y3 <= Y2; Z3 <= Z2; X3_inf <= X2_inf;
                busy <= 1'b0; done <= 1'b1; state <= E_IDLE;
            end else if (X2_inf) begin
                X3 <= X1; Y3 <= Y1; Z3 <= Z1; X3_inf <= X1_inf;
                busy <= 1'b0; done <= 1'b1; state <= E_IDLE;
            end else begin
                ma <= Z1; mb <= Z1; mul_start <= 1'b1;              // Z1Z1
                state <= E_A1;
            end
        end
 
        E_A1: if (mul_done) begin
            t0 <= mul_res;                                          // Z1Z1
            ma <= Z2; mb <= Z2; mul_start <= 1'b1;                  // Z2Z2
            state <= E_A2;
        end
 
        E_A2: if (mul_done) begin
            t1 <= mul_res;                                          // Z2Z2
            ma <= X1; mb <= mul_res; mul_start <= 1'b1;              // U1
            state <= E_A3;
        end
 
        E_A3: if (mul_done) begin
            t2 <= mul_res;                                          // U1
            ma <= X2; mb <= t0; mul_start <= 1'b1;                   // U2
            state <= E_A4;
        end
 
        E_A4: if (mul_done) begin
            t3 <= mul_res;                                          // U2
            ma <= Z1; mb <= t0; mul_start <= 1'b1;                   // Z1CUBE
            state <= E_A5;
        end
 
        E_A5: if (mul_done) begin
            t4 <= mul_res;                                          // Z1CUBE
            ma <= Z2; mb <= t1; mul_start <= 1'b1;                   // Z2CUBE
            state <= E_A6;
        end
 
        E_A6: if (mul_done) begin
            t5 <= mul_res;                                          // Z2CUBE
            ma <= Y1; mb <= mul_res; mul_start <= 1'b1;              // S1
            state <= E_A7;
        end
 
        E_A7: if (mul_done) begin
            t6 <= mul_res;                                          // S1
            ma <= Y2; mb <= t4; mul_start <= 1'b1;                   // S2
            state <= E_A8;
        end
 
        E_A8: if (mul_done) begin
            t7 <= mul_res;                                          // S2
            alu_a <= t3; alu_b <= t2; alu_sub <= 1'b1;                // H=U2-U1
            alu_start <= 1'b1;
            state <= E_A9;
        end
 
        E_A9: if (alu_done) begin
            t8 <= alu_y;                                             // H
            alu_a <= t7; alu_b <= t6; alu_sub <= 1'b1;                // R=S2-S1
            alu_start <= 1'b1;
            state <= E_A10;
        end
 
        E_A10: if (alu_done) begin
            t9 <= alu_y;                                             // R
            state <= E_A11;
        end
 
        E_A11: begin
            if (t8 == 0) begin
                if (t9 == 0) begin
                    // P1 == P2 : fall through into the SAME doubling
                    // datapath used above - no second doubler needed.
                    state <= E_D_ENTRY;
                end else begin
                    X3 <= 0; Y3 <= 1; Z3 <= 0; X3_inf <= 1'b1;
                    busy <= 1'b0; done <= 1'b1; state <= E_IDLE;
                end
            end else begin
                ma <= t8; mb <= t8; mul_start <= 1'b1;                // HH=H*H
                state <= E_A12;
            end
        end
 
        E_A12: if (mul_done) begin
            t10 <= mul_res;                                          // HH
            ma <= t8; mb <= mul_res; mul_start <= 1'b1;               // HHH
            state <= E_A13;
        end
 
        E_A13: if (mul_done) begin
            t11 <= mul_res;                                          // HHH
            ma <= t2; mb <= t10; mul_start <= 1'b1;                   // V=U1*HH
            state <= E_A14;
        end
 
        E_A14: if (mul_done) begin
            t12 <= mul_res;                                          // V
            ma <= t9; mb <= t9; mul_start <= 1'b1;                    // R2=R*R
            state <= E_A15;
        end
 
        E_A15: if (mul_done) begin
            alu_a <= mul_res; alu_b <= t11; alu_sub <= 1'b1;          // R2-HHH
            alu_start <= 1'b1;
            state <= E_A16;
        end
 
        E_A16: if (alu_done) begin
            t0 <= alu_y;                                              // X3_tmp
            alu_a <= t12; alu_b <= t12; alu_sub <= 1'b0;               // 2*V
            alu_start <= 1'b1;
            state <= E_A17;
        end
 
        E_A17: if (alu_done) begin
            t1 <= alu_y;                                              // V2
            alu_a <= t0; alu_b <= alu_y; alu_sub <= 1'b1;              // X3
            alu_start <= 1'b1;
            state <= E_A18;
        end
 
        E_A18: if (alu_done) begin
            X3 <= alu_y;                                              // X3
            alu_a <= t12; alu_b <= alu_y; alu_sub <= 1'b1;             // V-X3
            alu_start <= 1'b1;
            state <= E_A19;
        end
 
        E_A19: if (alu_done) begin
            t2 <= alu_y;                                              // VX3
            ma <= t9; mb <= alu_y; mul_start <= 1'b1;                  // R*VX3
            state <= E_A20;
        end
 
        E_A20: if (mul_done) begin
            t3 <= mul_res;                                            // RVX
            ma <= t6; mb <= t11; mul_start <= 1'b1;                    // S1*HHH
            state <= E_A21;
        end
 
        E_A21: if (mul_done) begin
            t4 <= mul_res;                                            // S1HHH
            alu_a <= t3; alu_b <= mul_res; alu_sub <= 1'b1;            // Y3
            alu_start <= 1'b1;
            state <= E_A22;
        end
 
        E_A22: if (alu_done) begin
            Y3 <= alu_y;                                              // Y3
            ma <= t8; mb <= Z1; mul_start <= 1'b1;                     // H*Z1
            state <= E_A23;
        end
 
        E_A23: if (mul_done) begin
            t0 <= mul_res;                                            // Z3a
            ma <= mul_res; mb <= Z2; mul_start <= 1'b1;                 // Z3a*Z2
            state <= E_A24;
        end
 
        E_A24: if (mul_done) begin
            Z3     <= mul_res;                                        // Z3
            X3_inf <= 1'b0;
            busy   <= 1'b0;
            done   <= 1'b1;
            state  <= E_IDLE;
        end
 
        default: state <= E_IDLE;
 
        endcase
    end
end
 
endmodule
