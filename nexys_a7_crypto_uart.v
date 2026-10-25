`timescale 1ns / 1ps

// ECIES (secp256k1 + AES-128 + HMAC-SHA256) accelerator, ASCII over UART
// 115200 8N1, every frame ends with '\n'.  All numbers are big-endian hex.
//
// RECEIVER side (holds the private key d)
//   'K' + d(64)                               -> "OK_PRIV"        load private key
//   'U'                                       -> Qx(64) Qy(64)    public key  Q = d*G
//   'R' + Rx(64) Ry(64) CT(32) TAG(64)        -> PT(32)           verify tag, decrypt
//
// SENDER side (knows only the receiver's PUBLIC key)
//   'Q' + Qx(64) Qy(64)                       -> "OK_PUB"         load recipient public key
//   'P' + r(64) PT(32)                        -> Rx(64) Ry(64) CT(32) TAG(64)
//         r = fresh random ephemeral scalar, 1 <= r < n (supplied by the PC)
//
// Errors: ERROR_ECC (point at infinity / scalar 0), ERROR_PT (point not on
//         curve), ERROR_TAG (authentication failed), ERROR_LEN (bad frame).
//
// Command letters must not be hex digits (A-F, a-f, 0-9), hence K/Q/U/P/R.
// After reset NO key is loaded: private key = 0, recipient key = (0,0), so
// any operation fails with an error until the keys have been set.

module nexys_a7_crypto_uart (
    input  wire        CLK100MHZ,
    input  wire        CPU_RESETN,
    input  wire        UART_RXD,
    output wire        UART_TXD,
    output wire [15:0] LED
);

    //------------------------------------------------------------------
    // 50 MHz clock (register name clk50_r must match the .xdc), on a BUFG
    //------------------------------------------------------------------
    reg clk50_r = 1'b0;
    always @(posedge CLK100MHZ) clk50_r <= ~clk50_r;

    wire clk;
    BUFG u_clk_bufg (.I(clk50_r), .O(clk));

    // Reset synchronizer (async assert, sync release)
    reg [1:0] rst_sync = 2'b00;
    always @(posedge clk or negedge CPU_RESETN) begin
        if (!CPU_RESETN) rst_sync <= 2'b00;
        else             rst_sync <= {rst_sync[0], 1'b1};
    end
    wire reset_n = rst_sync[1];

    //------------------------------------------------------------------
    // UART
    //------------------------------------------------------------------
    wire [7:0] rx_data;
    wire       rx_valid;
    uart_rx #(.CLKS_PER_BIT(434)) u_rx (
        .clk(clk), .reset_n(reset_n), .rx(UART_RXD),
        .data(rx_data), .valid(rx_valid)
    );

    reg  [7:0] tx_data;
    reg        tx_start;
    wire       tx_busy;
    uart_tx #(.CLKS_PER_BIT(434)) u_tx (
        .clk(clk), .reset_n(reset_n), .tx(UART_TXD),
        .data(tx_data), .start(tx_start), .busy(tx_busy)
    );

    //------------------------------------------------------------------
    // Key storage.  The private key d is used ONLY by DECRYPT / PUBKEY,
    // the recipient public key Q ONLY by ENCRYPT: sender and receiver
    // paths never share a secret.
    //------------------------------------------------------------------
    reg [255:0] d_reg;                     // receiver private key
    reg [255:0] q_x, q_y;                  // recipient public key (sender side)
    reg         have_priv, have_pub;

    //------------------------------------------------------------------
    // Crypto core
    //------------------------------------------------------------------
    localparam [1:0] M_DEC = 2'd0, M_ENC = 2'd1, M_PUB = 2'd2;

    reg          crypto_start;
    reg  [1:0]   op_mode;                  // mode of the operation in flight
    reg  [895:0] rx_shift_reg;             // longest frame: 224 hex chars

    // field views of the received frame (MSB-first hex => last chars in LSBs)
    //   'P': r(64) PT(32)                  'R': Rx(64) Ry(64) CT(32) TAG(64)
    wire [255:0] f_r    = rx_shift_reg[383:128];
    wire [127:0] f_pt   = rx_shift_reg[127:0];
    wire [255:0] f_rx   = rx_shift_reg[895:640];
    wire [255:0] f_ry   = rx_shift_reg[639:384];
    wire [127:0] f_ct   = rx_shift_reg[383:256];
    wire [255:0] f_tag  = rx_shift_reg[255:0];

    wire [255:0] crypto_scalar  = (op_mode == M_ENC) ? f_r  : d_reg;
    wire [255:0] crypto_pub_x   = (op_mode == M_ENC) ? q_x  : f_rx;
    wire [255:0] crypto_pub_y   = (op_mode == M_ENC) ? q_y  : f_ry;
    wire [127:0] crypto_data_in = (op_mode == M_ENC) ? f_pt : f_ct;

    wire [255:0] crypto_out_x, crypto_out_y, crypto_tag_out;
    wire [127:0] crypto_data_out;
    wire         crypto_tag_match, crypto_busy, crypto_done, crypto_error;
    wire [1:0]   crypto_err_code;

    unified_crypto_top dut (
        .clk(clk), .reset_n(reset_n),
        .start(crypto_start), .mode(op_mode),
        .scalar(crypto_scalar), .pub_x(crypto_pub_x), .pub_y(crypto_pub_y),
        .data_in(crypto_data_in), .rx_tag(f_tag),
        .out_x(crypto_out_x), .out_y(crypto_out_y),
        .data_out(crypto_data_out), .tag_out(crypto_tag_out),
        .tag_match(crypto_tag_match),
        .busy(crypto_busy), .done(crypto_done), .error(crypto_error),
        .err_code(crypto_err_code)
    );

    //------------------------------------------------------------------
    // Helpers
    //------------------------------------------------------------------
    function is_hex(input [7:0] c);
        begin
            is_hex = (c >= 8'h30 && c <= 8'h39) ||
                     (c >= 8'h41 && c <= 8'h46) ||
                     (c >= 8'h61 && c <= 8'h66);
        end
    endfunction

    function [3:0] ascii2hex(input [7:0] ascii);
        begin
            if      (ascii >= 8'h30 && ascii <= 8'h39) ascii2hex = ascii - 8'h30;
            else if (ascii >= 8'h41 && ascii <= 8'h46) ascii2hex = ascii - 8'h37;
            else if (ascii >= 8'h61 && ascii <= 8'h66) ascii2hex = ascii - 8'h57;
            else                                       ascii2hex = 4'd0;
        end
    endfunction

    function [7:0] hex2ascii(input [3:0] hex);
        begin
            if (hex <= 4'h9) hex2ascii = {4'h3, hex};
            else             hex2ascii = 8'h37 + hex;
        end
    endfunction

    localparam [7:0] CH_K = 8'h4B, CH_Q = 8'h51, CH_U = 8'h55,
                     CH_P = 8'h50, CH_R = 8'h52;

    localparam [2:0] C_NONE = 3'd0, C_K = 3'd1, C_Q = 3'd2, C_U = 3'd3,
                     C_P    = 3'd4, C_R = 3'd5;

    localparam [1:0] TX_IDLE = 2'd0, TX_DATA = 2'd1, TX_ERR = 2'd2, TX_NL = 2'd3;
    reg [1:0]   tx_state;
    reg [895:0] tx_shift_reg;
    reg [79:0]  err_shift_reg;             // 10-char text message
    reg [7:0]   tx_char_cnt;

    //------------------------------------------------------------------
    // Command parser
    //------------------------------------------------------------------
    reg [2:0] cmd;
    reg [7:0] rx_cnt;          // hex chars received since the command letter
    reg       op_active;       // crypto operation in flight: freeze inputs
    reg       len_err;         // 1-cycle pulses
    reg       ack_priv, ack_pub;
    reg       rx_toggle;       // debug

    reg [7:0] exp_cnt;
    always @(*) begin
        case (cmd)
            C_K:     exp_cnt = 8'd64;
            C_Q:     exp_cnt = 8'd128;
            C_U:     exp_cnt = 8'd0;
            C_P:     exp_cnt = 8'd96;
            C_R:     exp_cnt = 8'd224;
            default: exp_cnt = 8'd0;
        endcase
    end

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            crypto_start <= 1'b0;
            op_mode      <= M_DEC;
            cmd          <= C_NONE;
            rx_shift_reg <= 896'd0;
            rx_cnt       <= 8'd0;
            op_active    <= 1'b0;
            len_err      <= 1'b0;
            ack_priv     <= 1'b0;
            ack_pub      <= 1'b0;
            rx_toggle    <= 1'b0;
            d_reg        <= 256'd0;
            q_x          <= 256'd0;
            q_y          <= 256'd0;
            have_priv    <= 1'b0;
            have_pub     <= 1'b0;
        end else begin
            crypto_start <= 1'b0;
            len_err      <= 1'b0;
            ack_priv     <= 1'b0;
            ack_pub      <= 1'b0;

            if (crypto_done || crypto_error) begin
                op_active    <= 1'b0;
                rx_shift_reg <= 896'd0;    // do not keep r / ciphertext lying around
            end

            if (rx_valid) begin
                rx_toggle <= ~rx_toggle;

                if (!op_active) begin
                    if (rx_data == CH_K || rx_data == CH_Q || rx_data == CH_U ||
                        rx_data == CH_P || rx_data == CH_R) begin
                        case (rx_data)
                            CH_K: cmd <= C_K;
                            CH_Q: cmd <= C_Q;
                            CH_U: cmd <= C_U;
                            CH_P: cmd <= C_P;
                            default: cmd <= C_R;
                        endcase
                        rx_shift_reg <= 896'd0;
                        rx_cnt       <= 8'd0;
                    end else if (rx_data == 8'h0A) begin          // '\n'
                        if (tx_state == TX_IDLE && cmd != C_NONE) begin
                            cmd <= C_NONE;                         // one execution per frame
                            if (rx_cnt == exp_cnt) begin
                                case (cmd)
                                    C_K: begin
                                        d_reg     <= rx_shift_reg[255:0];
                                        have_priv <= 1'b1;
                                        ack_priv  <= 1'b1;
                                    end
                                    C_Q: begin
                                        q_x       <= rx_shift_reg[511:256];
                                        q_y       <= rx_shift_reg[255:0];
                                        have_pub  <= 1'b1;
                                        ack_pub   <= 1'b1;
                                    end
                                    C_U: begin
                                        op_mode      <= M_PUB;
                                        crypto_start <= 1'b1;
                                        op_active    <= 1'b1;
                                    end
                                    C_P: begin
                                        op_mode      <= M_ENC;
                                        crypto_start <= 1'b1;
                                        op_active    <= 1'b1;
                                    end
                                    default: begin                 // C_R
                                        op_mode      <= M_DEC;
                                        crypto_start <= 1'b1;
                                        op_active    <= 1'b1;
                                    end
                                endcase
                                // config frames hold secrets: clear the buffer
                                if (cmd == C_K || cmd == C_Q) rx_shift_reg <= 896'd0;
                            end else begin
                                len_err <= 1'b1;
                            end
                        end
                    end else if (is_hex(rx_data)) begin
                        rx_shift_reg <= {rx_shift_reg[891:0], ascii2hex(rx_data)};
                        if (rx_cnt != 8'hFF) rx_cnt <= rx_cnt + 1'b1;
                    end
                    // anything else ('\r', spaces, ...) is ignored
                end
            end
        end
    end

    //------------------------------------------------------------------
    // Response transmitter
    // `done` / `error` from the core are 1-cycle pulses.
    //------------------------------------------------------------------
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            tx_state      <= TX_IDLE;
            tx_start      <= 1'b0;
            tx_data       <= 8'd0;
            tx_char_cnt   <= 8'd0;
            tx_shift_reg  <= 896'd0;
            err_shift_reg <= 80'd0;
        end else begin
            tx_start <= 1'b0;
            case (tx_state)
                TX_IDLE: begin
                    if (crypto_error) begin
                        case (crypto_err_code)
                            2'd1:    err_shift_reg <= "ERROR_ECC ";
                            2'd2:    err_shift_reg <= "ERROR_PT  ";
                            default: err_shift_reg <= "ERROR_TAG ";
                        endcase
                        tx_char_cnt <= 8'd10;
                        tx_state    <= TX_ERR;
                    end else if (crypto_done) begin
                        case (op_mode)
                            M_ENC: begin   // R || CT || TAG
                                tx_shift_reg <= {crypto_out_x, crypto_out_y,
                                                 crypto_data_out, crypto_tag_out};
                                tx_char_cnt  <= 8'd224;
                            end
                            M_PUB: begin   // Q
                                tx_shift_reg <= {crypto_out_x, crypto_out_y, 384'd0};
                                tx_char_cnt  <= 8'd128;
                            end
                            default: begin // PT
                                tx_shift_reg <= {crypto_data_out, 768'd0};
                                tx_char_cnt  <= 8'd32;
                            end
                        endcase
                        tx_state <= TX_DATA;
                    end else if (len_err) begin
                        err_shift_reg <= "ERROR_LEN ";
                        tx_char_cnt   <= 8'd10;
                        tx_state      <= TX_ERR;
                    end else if (ack_priv) begin
                        err_shift_reg <= "OK_PRIV   ";
                        tx_char_cnt   <= 8'd10;
                        tx_state      <= TX_ERR;
                    end else if (ack_pub) begin
                        err_shift_reg <= "OK_PUB    ";
                        tx_char_cnt   <= 8'd10;
                        tx_state      <= TX_ERR;
                    end
                end

                TX_DATA: begin
                    if (!tx_busy && !tx_start) begin
                        if (tx_char_cnt != 0) begin
                            tx_data      <= hex2ascii(tx_shift_reg[895:892]);
                            tx_shift_reg <= {tx_shift_reg[891:0], 4'd0};
                            tx_start     <= 1'b1;
                            tx_char_cnt  <= tx_char_cnt - 1'b1;
                        end else tx_state <= TX_NL;
                    end
                end

                TX_ERR: begin
                    if (!tx_busy && !tx_start) begin
                        if (tx_char_cnt != 0) begin
                            tx_data       <= err_shift_reg[79:72];
                            err_shift_reg <= {err_shift_reg[71:0], 8'd0};
                            tx_start      <= 1'b1;
                            tx_char_cnt   <= tx_char_cnt - 1'b1;
                        end else tx_state <= TX_NL;
                    end
                end

                TX_NL: begin
                    if (!tx_busy && !tx_start) begin
                        tx_data  <= 8'h0A;
                        tx_start <= 1'b1;
                        tx_state <= TX_IDLE;
                    end
                end
            endcase
        end
    end

    //------------------------------------------------------------------
    // Debug LEDs (done/error are 1-cycle pulses, so they are latched)
    //------------------------------------------------------------------
    reg led_done, led_err, led_tag;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            led_done <= 1'b0;
            led_err  <= 1'b0;
            led_tag  <= 1'b0;
        end else begin
            if (crypto_start) begin led_done <= 1'b0; led_err <= 1'b0; led_tag <= 1'b0; end
            if (crypto_done)  begin led_done <= 1'b1; led_tag <= crypto_tag_match; end
            if (crypto_error) led_err  <= 1'b1;
        end
    end

    assign LED[0]    = led_done;       // last operation finished OK
    assign LED[1]    = led_err;        // last operation failed
    assign LED[2]    = crypto_busy;
    assign LED[3]    = led_tag;        // last DECRYPT: authentication tag verified
    assign LED[4]    = rx_toggle;      // toggles on every received byte
    assign LED[5]    = tx_busy;
    assign LED[6]    = have_priv;      // receiver private key loaded
    assign LED[7]    = have_pub;       // recipient public key loaded
    assign LED[15:8] = {6'd0, op_mode};// mode of the last operation (0 dec, 1 enc, 2 pubkey)

endmodule
