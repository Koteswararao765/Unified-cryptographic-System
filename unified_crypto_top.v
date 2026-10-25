`timescale 1ns / 1ps
//======================================================================
// unified_crypto_top  --  ECIES on secp256k1 (sender / receiver)
//
//   Receiver key pair : private d (secret), public Q = d*G
//   Sender            : knows ONLY Q.  Per message it picks a fresh
//                       random ephemeral scalar r and sends R = r*G.
//
//   ENCRYPT (sender)   validate Q
//                      R  = r*G              -> out_x,out_y (sent to receiver)
//                      S  = r*Q              (shared point, never leaves chip)
//                      (K_enc || K_mac) = SHA-256( S.x || 00000001 )   [X9.63 KDF]
//                      CT  = AES-128-ENC(K_enc, PT)
//                      TAG = HMAC-SHA256(K_mac, CT)
//
//   DECRYPT (receiver) validate R
//                      S  = d*R              (= r*Q  because  d*r*G = r*d*G)
//                      same KDF  -> K_enc, K_mac
//                      TAG' = HMAC-SHA256(K_mac, CT)  ; must equal TAG
//                      PT  = AES-128-DEC(K_enc, CT)   (only if the tag matched)
//
//   PUBKEY             Q = d*G  -> out_x,out_y
//
// The sender never needs d, the receiver never needs r.  Both sides get
// the same key because  r*(d*G) == d*(r*G).
//
// secp256k1 has cofactor 1, so no cofactor multiplication is needed.
//======================================================================
module unified_crypto_top (
    input  wire         clk,
    input  wire         reset_n,

    input  wire         start,          // 1-cycle pulse
    input  wire [1:0]   mode,           // 0 = DECRYPT, 1 = ENCRYPT, 2 = PUBKEY

    input  wire [255:0] scalar,         // ENCRYPT: ephemeral r.   DECRYPT/PUBKEY: private key d
    input  wire [255:0] pub_x,          // ENCRYPT: recipient public Q.  DECRYPT: sender's R
    input  wire [255:0] pub_y,
    input  wire [127:0] data_in,        // ENCRYPT: plaintext.  DECRYPT: ciphertext
    input  wire [255:0] rx_tag,         // DECRYPT: received authentication tag

    output reg  [255:0] out_x,          // ENCRYPT: R = r*G.   PUBKEY: Q = d*G
    output reg  [255:0] out_y,
    output reg  [127:0] data_out,       // ENCRYPT: ciphertext. DECRYPT: plaintext
    output reg  [255:0] tag_out,        // ENCRYPT: tag to send. DECRYPT: locally recomputed tag
    output reg          tag_match,      // DECRYPT: 1 = tag verified

    output reg          busy,
    output reg          done,           // 1-cycle pulse, success
    output reg          error,          // 1-cycle pulse, failure (see err_code)
    output reg  [1:0]   err_code        // 1 = point at infinity / bad scalar
                                        // 2 = point not on curve
                                        // 3 = authentication tag mismatch
);

    localparam [1:0] M_DEC = 2'd0, M_ENC = 2'd1, M_PUB = 2'd2;
    localparam [1:0] E_NONE = 2'd0, E_ECC = 2'd1, E_PT = 2'd2, E_TAG = 2'd3;

    // secp256k1 base point G (public domain parameter)
    localparam [255:0] GX = 256'h79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798;
    localparam [255:0] GY = 256'h483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8;

    //------------------------------------------------------------------
    // Latched operands (inputs only need to be valid in the start cycle)
    //------------------------------------------------------------------
    reg [1:0]   mode_l;
    reg [255:0] k_l, px_l, py_l;
    reg [127:0] data_l;
    reg [255:0] tag_l;

    reg         sel_g;        // 1: ECC point input = G ; 0: = (px_l,py_l)
    reg         second;       // ENCRYPT: 0 = computing R=r*G, 1 = computing S=r*Q
    reg [255:0] shared_x;     // x-coordinate of the ECDH shared point
    reg [255:0] kdf;          // {K_enc[127:0], K_mac[127:0]}
    reg [255:0] inner;        // HMAC inner digest
    reg [127:0] mac_ct;       // ciphertext that is being authenticated

    //------------------------------------------------------------------
    // ECC core
    //------------------------------------------------------------------
    reg          ecc_start, chk_start;
    wire [255:0] ecc_rx_w, ecc_ry_w;
    wire         ecc_inf_w, ecc_done_w, chk_done_w, chk_ok_w;

    ecc_top_256_iter ecc_inst (
        .clk(clk), .rst(~reset_n),
        .start(ecc_start),
        .k(k_l),
        .Px(sel_g ? GX : px_l),
        .Py(sel_g ? GY : py_l),
        .Rx(ecc_rx_w), .Ry(ecc_ry_w), .Rx_inf(ecc_inf_w), .done(ecc_done_w),
        .chk_start(chk_start), .chk_done(chk_done_w), .chk_ok(chk_ok_w)
    );

    //------------------------------------------------------------------
    // SHA-256 core + small sequencer (1 or 2 blocks per hash)
    //------------------------------------------------------------------
    reg          sha_init, sha_next;
    reg  [511:0] sha_block;
    wire         sha_ready_w, sha_valid_w;
    wire [255:0] sha_digest_w;

    sha256_core sha_inst (
        .clk(clk), .reset_n(reset_n),
        .init(sha_init), .next(sha_next), .mode(1'b1),
        .block(sha_block),
        .ready(sha_ready_w), .digest(sha_digest_w), .digest_valid(sha_valid_w)
    );

    reg          hs_go, hs_two;
    reg  [511:0] hs_b0, hs_b1;
    reg          hs_done;
    reg  [255:0] hs_digest;

    localparam [2:0] HS_IDLE = 3'd0, HS_INITD = 3'd1, HS_RDY = 3'd2,
                     HS_NEXTD = 3'd3, HS_WAITV = 3'd4;
    reg [2:0] hs_state;

    // The *D states are deliberate 1-cycle gaps: they let the core drop
    // `ready` / clear a stale `digest_valid` before it is sampled again.
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            hs_state  <= HS_IDLE;
            sha_init  <= 1'b0;
            sha_next  <= 1'b0;
            sha_block <= 512'd0;
            hs_done   <= 1'b0;
            hs_digest <= 256'd0;
        end else begin
            sha_init <= 1'b0;
            sha_next <= 1'b0;
            hs_done  <= 1'b0;
            case (hs_state)
                HS_IDLE:  if (hs_go) begin
                              sha_block <= hs_b0;
                              sha_init  <= 1'b1;
                              hs_state  <= HS_INITD;
                          end
                HS_INITD: hs_state <= hs_two ? HS_RDY : HS_WAITV;
                HS_RDY:   if (sha_ready_w) begin
                              sha_block <= hs_b1;
                              sha_next  <= 1'b1;
                              hs_state  <= HS_NEXTD;
                          end
                HS_NEXTD: hs_state <= HS_WAITV;
                HS_WAITV: if (sha_valid_w) begin
                              hs_digest <= sha_digest_w;
                              hs_done   <= 1'b1;
                              hs_state  <= HS_IDLE;
                          end
                default:  hs_state <= HS_IDLE;
            endcase
        end
    end

    //------------------------------------------------------------------
    // AES-128 core
    //------------------------------------------------------------------
    reg          aes_init, aes_next, aes_encdec;
    reg  [255:0] aes_key_full;
    wire         aes_ready_w, aes_valid_w;
    wire [127:0] aes_result_w;

    aes_core aes_inst (
        .clk(clk), .reset_n(reset_n),
        .encdec(aes_encdec), .init(aes_init), .next(aes_next),
        .ready(aes_ready_w),
        .key(aes_key_full), .keylen(1'b0),          // AES-128
        .block(data_l),
        .result(aes_result_w), .result_valid(aes_valid_w)
    );

    //------------------------------------------------------------------
    // Message construction (SHA-256 padding done here, all single-purpose)
    //------------------------------------------------------------------
    // KDF   : Sx(256) || counter 00000001 (32)           = 288 bits
    wire [511:0] kdf_block   = {shared_x, 32'd1, 1'b1, 159'd0, 64'd288};
    // HMAC  : K0 = K_mac zero-padded to 64 bytes
    wire [511:0] k0          = {kdf[127:0], 384'd0};
    wire [511:0] ipad_block  = k0 ^ {64{8'h36}};
    wire [511:0] opad_block  = k0 ^ {64{8'h5c}};
    // inner : (K0^ipad)(512) || CT(128)  -> 640 bits total length
    wire [511:0] inner_b1    = {mac_ct, 1'b1, 319'd0, 64'd640};
    // outer : (K0^opad)(512) || inner(256) -> 768 bits total length
    wire [511:0] outer_b1    = {inner, 1'b1, 191'd0, 64'd768};

    //------------------------------------------------------------------
    // Main FSM
    //------------------------------------------------------------------
    localparam [3:0]
        S_IDLE     = 4'd0,
        S_VAL_W    = 4'd1,    // wait for point validation
        S_ECC_W    = 4'd2,    // wait for scalar multiplication
        S_KDF_GO   = 4'd3,
        S_KDF_W    = 4'd4,
        S_AES_INIT = 4'd5,
        S_AES_W1   = 4'd6,
        S_AES_NEXT = 4'd7,
        S_AES_W2   = 4'd8,
        S_HI_GO    = 4'd9,    // HMAC inner
        S_HI_W     = 4'd10,
        S_HO_GO    = 4'd11,   // HMAC outer
        S_HO_W     = 4'd12,
        S_DONE     = 4'd13,
        S_ERROR    = 4'd14;

    reg [3:0] state;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state        <= S_IDLE;
            mode_l       <= M_DEC;
            k_l          <= 256'd0;
            px_l         <= 256'd0;
            py_l         <= 256'd0;
            data_l       <= 128'd0;
            tag_l        <= 256'd0;
            sel_g        <= 1'b0;
            second       <= 1'b0;
            shared_x     <= 256'd0;
            kdf          <= 256'd0;
            inner        <= 256'd0;
            mac_ct       <= 128'd0;
            ecc_start    <= 1'b0;
            chk_start    <= 1'b0;
            hs_go        <= 1'b0;
            hs_two       <= 1'b0;
            hs_b0        <= 512'd0;
            hs_b1        <= 512'd0;
            aes_init     <= 1'b0;
            aes_next     <= 1'b0;
            aes_encdec   <= 1'b1;
            aes_key_full <= 256'd0;
            out_x        <= 256'd0;
            out_y        <= 256'd0;
            data_out     <= 128'd0;
            tag_out      <= 256'd0;
            tag_match    <= 1'b0;
            busy         <= 1'b0;
            done         <= 1'b0;
            error        <= 1'b0;
            err_code     <= E_NONE;
        end else begin
            // control pulses are one cycle long
            ecc_start <= 1'b0;
            chk_start <= 1'b0;
            hs_go     <= 1'b0;
            aes_init  <= 1'b0;
            aes_next  <= 1'b0;

            case (state)

                //-----------------------------------------------------
                S_IDLE: begin
                    done  <= 1'b0;
                    error <= 1'b0;
                    busy  <= 1'b0;
                    // wipe key material while idle
                    k_l          <= 256'd0;
                    shared_x     <= 256'd0;
                    kdf          <= 256'd0;
                    aes_key_full <= 256'd0;

                    if (start) begin
                        busy      <= 1'b1;
                        mode_l    <= mode;
                        k_l       <= scalar;
                        px_l      <= pub_x;
                        py_l      <= pub_y;
                        data_l    <= data_in;
                        tag_l     <= rx_tag;
                        second    <= 1'b0;
                        tag_match <= 1'b0;
                        err_code  <= E_NONE;
                        if (mode == M_PUB) begin
                            sel_g     <= 1'b1;            // Q = d*G
                            ecc_start <= 1'b1;
                            state     <= S_ECC_W;
                        end else begin
                            sel_g     <= 1'b0;            // validate (pub_x,pub_y) first
                            chk_start <= 1'b1;
                            state     <= S_VAL_W;
                        end
                    end
                end

                //-----------------------------------------------------
                // Reject points that are not on secp256k1
                //-----------------------------------------------------
                S_VAL_W: if (chk_done_w) begin
                    if (chk_ok_w) begin
                        sel_g     <= (mode_l == M_ENC);   // ENCRYPT: first R = r*G
                        ecc_start <= 1'b1;                // DECRYPT: S = d*R
                        state     <= S_ECC_W;
                    end else begin
                        err_code <= E_PT;
                        state    <= S_ERROR;
                    end
                end

                //-----------------------------------------------------
                S_ECC_W: if (ecc_done_w) begin
                    if (ecc_inf_w) begin
                        err_code <= E_ECC;
                        state    <= S_ERROR;
                    end else if (mode_l == M_PUB) begin
                        out_x <= ecc_rx_w;                // Q = d*G
                        out_y <= ecc_ry_w;
                        state <= S_DONE;
                    end else if (mode_l == M_ENC && !second) begin
                        out_x     <= ecc_rx_w;            // R = r*G  (sent to receiver)
                        out_y     <= ecc_ry_w;
                        second    <= 1'b1;
                        sel_g     <= 1'b0;                // now S = r*Q
                        ecc_start <= 1'b1;
                    end else begin
                        shared_x <= ecc_rx_w;             // S.x
                        state    <= S_KDF_GO;
                    end
                end

                //-----------------------------------------------------
                // KDF : SHA-256(S.x || 00000001)
                //-----------------------------------------------------
                S_KDF_GO: begin
                    hs_b0  <= kdf_block;
                    hs_two <= 1'b0;
                    hs_go  <= 1'b1;
                    state  <= S_KDF_W;
                end

                S_KDF_W: if (hs_done) begin
                    kdf          <= hs_digest;                        // K_enc || K_mac
                    aes_key_full <= {hs_digest[255:128], 128'd0};     // AES-128 key
                    if (mode_l == M_ENC) begin
                        aes_encdec <= 1'b1;
                        aes_init   <= 1'b1;
                        state      <= S_AES_INIT;
                    end else begin
                        mac_ct <= data_l;                 // verify tag BEFORE decrypting
                        state  <= S_HI_GO;
                    end
                end

                //-----------------------------------------------------
                // AES-128 (encrypt or decrypt)
                //-----------------------------------------------------
                S_AES_INIT: state <= S_AES_W1;

                S_AES_W1: if (aes_ready_w) begin
                    aes_next <= 1'b1;
                    state    <= S_AES_NEXT;
                end

                S_AES_NEXT: state <= S_AES_W2;

                S_AES_W2: if (aes_valid_w) begin
                    data_out <= aes_result_w;
                    if (mode_l == M_ENC) begin
                        mac_ct <= aes_result_w;           // encrypt-then-MAC
                        state  <= S_HI_GO;
                    end else begin
                        state  <= S_DONE;
                    end
                end

                //-----------------------------------------------------
                // HMAC-SHA256(K_mac, CT)  = H( K0^opad || H( K0^ipad || CT ) )
                //-----------------------------------------------------
                S_HI_GO: begin
                    hs_b0  <= ipad_block;
                    hs_b1  <= inner_b1;
                    hs_two <= 1'b1;
                    hs_go  <= 1'b1;
                    state  <= S_HI_W;
                end

                S_HI_W: if (hs_done) begin
                    inner <= hs_digest;
                    state <= S_HO_GO;
                end

                S_HO_GO: begin
                    hs_b0  <= opad_block;
                    hs_b1  <= outer_b1;
                    hs_two <= 1'b1;
                    hs_go  <= 1'b1;
                    state  <= S_HO_W;
                end

                S_HO_W: if (hs_done) begin
                    tag_out <= hs_digest;
                    if (mode_l == M_ENC) begin
                        state <= S_DONE;                  // tag goes out with the ciphertext
                    end else if (hs_digest == tag_l) begin
                        tag_match    <= 1'b1;
                        aes_encdec   <= 1'b0;             // decipher datapath
                        aes_init     <= 1'b1;
                        state        <= S_AES_INIT;
                    end else begin
                        err_code <= E_TAG;
                        state    <= S_ERROR;
                    end
                end

                //-----------------------------------------------------
                S_DONE: begin
                    done <= 1'b1;
                    busy <= 1'b0;
                    if (!start) state <= S_IDLE;
                end

                S_ERROR: begin
                    error <= 1'b1;
                    busy  <= 1'b0;
                    if (!start) state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
