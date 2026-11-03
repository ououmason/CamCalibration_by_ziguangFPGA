`timescale 1ns/1ps
`default_nettype none

// Full DDR RGB frame -> EVID/UDP -> the proven ETH stack and RGMII interface.
// DDR stores groups of R[32], G[32], B[32]. Network payload is interleaved RGB.
// One frame is pinned until the final packet finishes on the MAC. No HDMI tap
// is used: the unthrottled 148.5 MHz pixel stream cannot fit in a 1 Gbit/s link.
module eth_ddr_video #(
    parameter W = 1920,
    parameter H = 1080,
    parameter LOCAL_MAC = 48'h11_11_11_11_11_11,
    parameter LOCAL_IP = 32'hC0_A8_01_0B,
    parameter LOCAL_PORT = 16'h8080,
    parameter DEST_IP = 32'hC0_A8_01_69,
    parameter DEST_PORT = 16'd1234
) (
    input wire clk,
    input wire arst_n,
    output wire frame_request,
    input wire frame_valid,
    output wire frame_release,
    output wire read_request,
    input wire read_ready,
    output wire [31:0] read_offset,
    input wire read_data_valid,
    input wire [255:0] read_data,
    input wire rgmii_rxc,
    input wire rgmii_rx_ctl,
    input wire [3:0] rgmii_rxd,
    output wire rgmii_txc,
    output wire rgmii_tx_ctl,
    output wire [3:0] rgmii_txd
);
    // Must match the ref_clock/RGMII wiring of the validated ethernet_test.
    wire shifted_rxc, eth_lock, eth_clk;
    wire core_rst_n, eth_rst_n;
    wire common_reset_n = arst_n && eth_lock;
    ref_clock eth_rx_clock (.clkin1(rgmii_rxc), .clkout0(shifted_rxc), .lock(eth_lock));
    ud_reset core_reset(clk, common_reset_n, core_rst_n);
    ud_reset eth_reset(eth_clk, common_reset_n, eth_rst_n);

    wire rx_dv;
    wire [7:0] rx_data;
    wire stack_tx_en;
    wire [7:0] stack_tx_data;
    reg tx_en_q, rx_dv_q;
    reg [7:0] tx_data_q, rx_data_q;
    always @(posedge eth_clk or negedge eth_rst_n) begin
        if (!eth_rst_n) begin
            tx_en_q <= 0; tx_data_q <= 0; rx_dv_q <= 0; rx_data_q <= 0;
        end else begin
            tx_en_q <= stack_tx_en; tx_data_q <= stack_tx_data;
            rx_dv_q <= rx_dv; rx_data_q <= rx_data;
        end
    end
    rgmii_interface phy_interface (
        .rst(~eth_rst_n), .rgmii_clk(eth_clk), .rgmii_clk_90p(1'b0),
        .mac_tx_data_valid(tx_en_q), .mac_tx_data(tx_data_q),
        .mac_rx_error(), .mac_rx_data_valid(rx_dv), .mac_rx_data(rx_data),
        .rgmii_rxc(shifted_rxc), .rgmii_rx_ctl(rgmii_rx_ctl), .rgmii_rxd(rgmii_rxd),
        .rgmii_txc(rgmii_txc), .rgmii_tx_ctl(rgmii_tx_ctl), .rgmii_txd(rgmii_txd)
    );

    // Exactly 960 RGB bytes (320 pixels, ten planar DDR groups) per packet.
    // Fixed 20-byte EVID header matches ../host_video_receiver.py.
    localparam PACKET_COUNT = W * H * 3 / 960;
    localparam [15:0] WIDTH_FIELD = W;
    localparam [15:0] HEIGHT_FIELD = H;
    localparam [15:0] COUNT_FIELD = PACKET_COUNT;
    localparam C_FRAME=0, C_HEADER=1, C_READ=2, C_RESPONSE=3,
               C_PIXELS=4, C_DRAIN=5, C_RELEASE=6;
    reg [2:0] cstate;
    reg [31:0] frame_number;
    reg [15:0] packet_index;
    reg [2:0] header_word;
    reg [3:0] group_index;
    reg [1:0] channel;
    reg [4:0] pixel_word;
    reg [31:0] group_offset;
    reg [255:0] red_word, green_word, blue_word;
    reg [31:0] fifo_wr_data;
    wire fifo_full, fifo_empty;
    wire [10:0] fifo_rd_level;
    wire [31:0] fifo_rd_data;
    wire fifo_wr_en = core_rst_n && !fifo_full &&
                      (cstate == C_HEADER || cstate == C_PIXELS);
    wire fifo_rd_en;

    function [7:0] rgb_byte;
        input [6:0] index;
        reg [4:0] pixel_index;
        begin
            pixel_index = index / 3;
            case (index % 3)
                0: rgb_byte = red_word[pixel_index*8 +: 8];
                1: rgb_byte = green_word[pixel_index*8 +: 8];
                default: rgb_byte = blue_word[pixel_index*8 +: 8];
            endcase
        end
    endfunction
    always @* begin
        fifo_wr_data = 0;
        if (cstate == C_HEADER) begin
            case (header_word)
                0: fifo_wr_data = 32'h45564944; // "EVID"
                1: fifo_wr_data = {WIDTH_FIELD, HEIGHT_FIELD};
                2: fifo_wr_data = frame_number;
                3: fifo_wr_data = {packet_index, COUNT_FIELD};
                4: fifo_wr_data = {16'd960, 16'd0};
                default: fifo_wr_data = 0;
            endcase
        end else if (cstate == C_PIXELS)
            fifo_wr_data = {rgb_byte({pixel_word,2'b00}),
                            rgb_byte({pixel_word,2'b00}+7'd1),
                            rgb_byte({pixel_word,2'b00}+7'd2),
                            rgb_byte({pixel_word,2'b00}+7'd3)};
    end
    eth_pkt_fifo packet_fifo (
        .wr_clk(clk), .wr_rst(~core_rst_n),
        .wr_en(fifo_wr_en), .wr_data(fifo_wr_data), .wr_full(fifo_full),
        .wr_water_level(), .almost_full(),
        .rd_clk(eth_clk), .rd_rst(~eth_rst_n),
        .rd_en(fifo_rd_en), .rd_data(fifo_rd_data), .rd_empty(fifo_empty),
        .rd_water_level(fifo_rd_level), .almost_empty()
    );

    wire tx_link_ready;
    reg frame_done_toggle;
    (* async_reg = "true" *) reg [1:0] link_sync;
    (* async_reg = "true" *) reg [2:0] done_sync;
    reg done_seen;
    assign frame_request = core_rst_n && cstate == C_FRAME && link_sync[1];
    // Cancel a pinned frame after network clock/PLL loss, without resetting DDR.
    assign frame_release = !core_rst_n || cstate == C_RELEASE;
    assign read_request = core_rst_n && cstate == C_READ && !fifo_full;
    assign read_offset = group_offset + {25'd0, channel, 5'd0};
    always @(posedge clk or negedge core_rst_n) begin
        if (!core_rst_n) begin
            cstate <= C_FRAME; frame_number <= 0; packet_index <= 0;
            header_word <= 0; group_index <= 0; channel <= 0;
            pixel_word <= 0; group_offset <= 0;
            red_word <= 0; green_word <= 0; blue_word <= 0;
            link_sync <= 0; done_sync <= 0; done_seen <= 0;
        end else begin
            link_sync <= {link_sync[0], tx_link_ready};
            done_sync <= {done_sync[1:0], frame_done_toggle};
            case (cstate)
                C_FRAME: if (frame_request && frame_valid) begin
                    frame_number <= frame_number + 1'b1;
                    packet_index <= 0; header_word <= 0; group_offset <= 0;
                    group_index <= 0; channel <= 0; done_seen <= done_sync[2];
                    cstate <= C_HEADER;
                end
                C_HEADER: if (fifo_wr_en) begin
                    header_word <= header_word + 1'b1;
                    if (header_word == 4) begin
                        channel <= 0; cstate <= C_READ;
                    end
                end
                C_READ: if (read_request && read_ready) cstate <= C_RESPONSE;
                C_RESPONSE: if (read_data_valid) begin
                    case (channel)
                        0: red_word <= read_data;
                        1: green_word <= read_data;
                        2: blue_word <= read_data;
                    endcase
                    if (channel == 2) begin
                        pixel_word <= 0; cstate <= C_PIXELS;
                    end else begin
                        channel <= channel + 1'b1; cstate <= C_READ;
                    end
                end
                C_PIXELS: if (fifo_wr_en) begin
                    pixel_word <= pixel_word + 1'b1;
                    if (pixel_word == 23) begin
                        group_offset <= group_offset + 32'd96;
                        channel <= 0;
                        if (group_index == 9) begin
                            group_index <= 0; header_word <= 0;
                            if (packet_index == PACKET_COUNT-1) cstate <= C_DRAIN;
                            else begin
                                packet_index <= packet_index + 1'b1;
                                cstate <= C_HEADER;
                            end
                        end else begin
                            group_index <= group_index + 1'b1; cstate <= C_READ;
                        end
                    end
                end
                C_DRAIN: if (done_sync[2] != done_seen) cstate <= C_RELEASE;
                C_RELEASE: cstate <= C_FRAME;
                default: cstate <= C_FRAME;
            endcase
        end
    end

    // Prebuffer one WHOLE packet before starting UDP: the validated stack's
    // app interface has no byte-level backpressure and an eight-clock delay.
    localparam T_BOOT=0, T_ARP=1, T_ARP_END=2, T_ARP_WAIT=3,
               T_IDLE=4, T_POP=5, T_STORE=6, T_REQUEST=7,
               T_FEED=8, T_END=9, T_GAP=10, T_START=11;
    reg [3:0] tstate;
    reg [31:0] timer;
    reg [7:0] load_index;
    reg [7:0] send_word;
    reg [1:0] send_lane;
    reg [31:0] current_word, next_word, first_word;
    reg packet_last;
    reg [31:0] packet_ram [0:244];
    wire udp_ack, arp_found, mac_missing, mac_end;
    wire app_request = tstate == T_REQUEST;
    wire app_valid = tstate == T_FEED;
    wire [7:0] app_byte = current_word[31 - {send_lane,3'b000} -: 8];
    assign fifo_rd_en = eth_rst_n && tstate == T_POP && !fifo_empty;
    assign tx_link_ready = eth_rst_n && tstate >= T_IDLE && !mac_missing;
    // eth_pkt_fifo OUTPUT_REG=0: synchronous read, sample on the following edge.
    always @(posedge eth_clk) begin
        if (tstate == T_STORE) packet_ram[load_index] <= fifo_rd_data;
        if (tstate == T_FEED && send_lane == 2 && send_word < 244)
            next_word <= packet_ram[send_word + 1'b1];
    end
    always @(posedge eth_clk or negedge eth_rst_n) begin
        if (!eth_rst_n) begin
            tstate <= T_BOOT; timer <= 0; load_index <= 0;
            send_word <= 0; send_lane <= 0; current_word <= 0;
            first_word <= 0; packet_last <= 0; frame_done_toggle <= 0;
        end else begin
            case (tstate)
                T_BOOT: if (timer == 32'd125_000_000-1) begin
                    timer <= 0; tstate <= T_ARP;
                end else timer <= timer + 1'b1;
                T_ARP: tstate <= T_ARP_END;
                T_ARP_END: if (mac_end) begin timer <= 0; tstate <= T_ARP_WAIT; end
                T_ARP_WAIT: if (!mac_missing || arp_found) begin
                    timer <= 0; tstate <= T_GAP;
                end else if (timer == 32'd125_000_000-1) begin
                    timer <= 0; tstate <= T_ARP;
                end else timer <= timer + 1'b1;
                T_IDLE: if (mac_missing) tstate <= T_ARP;
                        else if (fifo_rd_level >= 245) begin
                            load_index <= 0; tstate <= T_POP;
                        end
                T_POP: if (fifo_rd_en) tstate <= T_STORE;
                T_STORE: begin
                    if (load_index == 0) first_word <= fifo_rd_data;
                    if (load_index == 3)
                        packet_last <= fifo_rd_data[31:16] == COUNT_FIELD-1'b1;
                    if (load_index == 244) tstate <= T_REQUEST;
                    else begin load_index <= load_index + 1'b1; tstate <= T_POP; end
                end
                T_REQUEST: if (udp_ack) begin
                    current_word <= first_word; send_word <= 0; send_lane <= 0;
                    tstate <= T_START;
                end
                // Match eth_udp_test's registered ram_wr_en startup latency.
                // IP asserts upper_data_req at count 29; UDP observes it at 30.
                // Start app data at 32: UDP header byte 0 -> mux at 33 -> IP at 34.
                // Starting at 31 would put byte 0 at IP count 33, where the final
                // destination-IP byte overrides it, shifting the whole UDP packet.
                T_START: tstate <= T_FEED;
                T_FEED: begin
                    send_lane <= send_lane + 1'b1;
                    if (send_lane == 3) begin
                        if (send_word == 244) tstate <= T_END;
                        else begin send_word <= send_word + 1'b1; current_word <= next_word; end
                    end
                end
                T_END: if (mac_end) begin
                    if (packet_last) frame_done_toggle <= ~frame_done_toggle;
                    timer <= 0; tstate <= T_GAP;
                end
                T_GAP: if (timer == 31) begin timer <= 0; tstate <= T_IDLE; end
                       else timer <= timer + 1'b1;
                default: tstate <= T_BOOT;
            endcase
        end
    end
    udp_ip_mac_top #(
        .LOCAL_MAC(LOCAL_MAC), .LOCAL_IP(LOCAL_IP), .LOCL_PORT(LOCAL_PORT),
        .DEST_IP(DEST_IP), .DEST_PORT(DEST_PORT)
    ) network_stack (
        .rgmii_clk(eth_clk), .rstn(eth_rst_n),
        .app_data_in_valid(app_valid), .app_data_in(app_byte),
        .app_data_length(16'd980), .app_data_request(app_request), .udp_send_ack(udp_ack),
        .arp_req(tstate == T_ARP), .arp_found(arp_found), .mac_not_exist(mac_missing),
        .mac_send_end(mac_end), .udp_rec_rdata(), .udp_rec_data_length(), .udp_rec_data_valid(),
        .mac_data_valid(stack_tx_en), .mac_tx_data(stack_tx_data),
        .rx_en(rx_dv_q), .mac_rx_datain(rx_data_q)
    );
endmodule
`default_nettype wire
