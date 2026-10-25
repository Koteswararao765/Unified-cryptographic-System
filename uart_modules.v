`timescale 1ns / 1ps

// 8-N-1 UART receiver. CLKS_PER_BIT = clk_freq / baud (50 MHz / 115200 = 434)
module uart_rx #(parameter CLKS_PER_BIT = 434) (
    input  wire       clk,
    input  wire       reset_n,
    input  wire       rx,
    output reg  [7:0] data,
    output reg        valid          // 1-cycle pulse when a byte is received
);
    // Two-flop synchronizer: rx is asynchronous to clk
    reg rx_meta, rx_sync;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            rx_meta <= 1'b1;
            rx_sync <= 1'b1;
        end else begin
            rx_meta <= rx;
            rx_sync <= rx_meta;
        end
    end

    localparam [2:0] IDLE = 3'd0, START_BIT = 3'd1, DATA_BITS = 3'd2,
                     STOP_BIT = 3'd3, CLEANUP = 3'd4;

    reg [2:0]  state;
    reg [15:0] clk_cnt;
    reg [2:0]  bit_cnt;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state   <= IDLE;
            valid   <= 1'b0;
            data    <= 8'd0;
            clk_cnt <= 16'd0;
            bit_cnt <= 3'd0;
        end else begin
            valid <= 1'b0;
            case (state)
                IDLE: begin
                    clk_cnt <= 16'd0;
                    if (!rx_sync) state <= START_BIT;
                end

                // wait half a bit, re-check start bit is still low (glitch filter)
                START_BIT: begin
                    if (clk_cnt == (CLKS_PER_BIT/2)) begin
                        clk_cnt <= 16'd0;
                        if (!rx_sync) begin
                            bit_cnt <= 3'd0;
                            state   <= DATA_BITS;
                        end else state <= IDLE;
                    end else clk_cnt <= clk_cnt + 1'b1;
                end

                // sample in the middle of each data bit, LSB first
                DATA_BITS: begin
                    if (clk_cnt < CLKS_PER_BIT-1) clk_cnt <= clk_cnt + 1'b1;
                    else begin
                        clk_cnt        <= 16'd0;
                        data[bit_cnt]  <= rx_sync;
                        if (bit_cnt == 3'd7) state <= STOP_BIT;
                        else bit_cnt <= bit_cnt + 1'b1;
                    end
                end

                STOP_BIT: begin
                    if (clk_cnt < CLKS_PER_BIT-1) clk_cnt <= clk_cnt + 1'b1;
                    else begin
                        valid <= 1'b1;
                        state <= CLEANUP;
                    end
                end

                CLEANUP: state <= IDLE;

                default: state <= IDLE;
            endcase
        end
    end
endmodule


// 8-N-1 UART transmitter
module uart_tx #(parameter CLKS_PER_BIT = 434) (
    input  wire       clk,
    input  wire       reset_n,
    input  wire       start,         // 1-cycle pulse, data latched on it
    input  wire [7:0] data,
    output reg        tx,
    output reg        busy
);
    localparam [1:0] IDLE = 2'd0, START_BIT = 2'd1, DATA_BITS = 2'd2, STOP_BIT = 2'd3;

    reg [1:0]  state;
    reg [15:0] clk_cnt;
    reg [2:0]  bit_cnt;
    reg [7:0]  tx_data;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state   <= IDLE;
            tx      <= 1'b1;
            busy    <= 1'b0;
            clk_cnt <= 16'd0;
            bit_cnt <= 3'd0;
            tx_data <= 8'd0;
        end else begin
            case (state)
                IDLE: begin
                    tx   <= 1'b1;
                    busy <= 1'b0;
                    if (start) begin
                        tx_data <= data;
                        busy    <= 1'b1;
                        clk_cnt <= 16'd0;
                        tx      <= 1'b0;          // start bit
                        state   <= START_BIT;
                    end
                end

                START_BIT: begin
                    if (clk_cnt < CLKS_PER_BIT-1) clk_cnt <= clk_cnt + 1'b1;
                    else begin
                        clk_cnt <= 16'd0;
                        tx      <= tx_data[0];
                        bit_cnt <= 3'd0;
                        state   <= DATA_BITS;
                    end
                end

                DATA_BITS: begin
                    if (clk_cnt < CLKS_PER_BIT-1) clk_cnt <= clk_cnt + 1'b1;
                    else begin
                        clk_cnt <= 16'd0;
                        if (bit_cnt == 3'd7) begin
                            tx    <= 1'b1;        // stop bit
                            state <= STOP_BIT;
                        end else begin
                            bit_cnt <= bit_cnt + 1'b1;
                            tx      <= tx_data[bit_cnt + 1'b1];
                        end
                    end
                end

                STOP_BIT: begin
                    if (clk_cnt < CLKS_PER_BIT-1) clk_cnt <= clk_cnt + 1'b1;
                    else state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end
endmodule

