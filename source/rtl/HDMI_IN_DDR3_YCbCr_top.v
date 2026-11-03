`timescale 1ns/1ps
`default_nettype none

module HDMI_IN_DDR3_YCbCr_top #(
    parameter MEM_ROW_ADDR_WIDTH        = 15,
    parameter MEM_COL_ADDR_WIDTH        = 10,
    parameter MEM_BADDR_WIDTH           = 3,
    parameter MEM_DQ_WIDTH              = 32,
    parameter MEM_DQS_WIDTH             = 4,
    parameter KEY_ACTIVE_LOW            = 1,
    parameter LED_ACTIVE_LOW            = 0,
    parameter KEY_DEBOUNCE_CYCLES       = 540000,
    parameter ETH_LOCAL_MAC            = 48'h11_11_11_11_11_11,
    parameter ETH_LOCAL_IP             = 32'hC0_A8_01_0B,
    parameter ETH_LOCAL_PORT           = 16'h8080,
    parameter ETH_DEST_IP              = 32'hC0_A8_01_69,
    parameter ETH_DEST_PORT            = 16'd1234
) (
    input  wire                       sys_clk,
    input  wire                       clk_p,
    input  wire                       clk_n,
    input  wire [3:0]                 key,

    output wire                       mem_rst_n,
    output wire                       mem_ck,
    output wire                       mem_ck_n,
    output wire                       mem_cke,
    output wire                       mem_cs_n,
    output wire                       mem_ras_n,
    output wire                       mem_cas_n,
    output wire                       mem_we_n,
    output wire                       mem_odt,

    output wire [MEM_ROW_ADDR_WIDTH-1:0] mem_a,
    output wire [MEM_BADDR_WIDTH-1:0]     mem_ba,

    inout  wire [MEM_DQ_WIDTH/8-1:0]    mem_dqs,
    inout  wire [MEM_DQ_WIDTH/8-1:0]    mem_dqs_n,
    inout  wire [MEM_DQ_WIDTH-1:0]      mem_dq,
    output wire [MEM_DQ_WIDTH/8-1:0]    mem_dm,

    output wire                       heart_beat_led,
    output wire                       ddr_init_done,
    output wire                       init_over_rx,

    output wire                       hd_scl,
    inout  wire                       hd_sda,
    output wire                       hdmi_int_led,

    input  wire                       pixclk_in,
    input  wire                       vs_in,
    input  wire                       hs_in,
    input  wire                       de_in,
    input  wire [7:0]                 r_in,
    input  wire [7:0]                 g_in,
    input  wire [7:0]                 b_in,

    output wire                       pix_clk,
    output wire                       vs_out,
    output wire                       hs_out,
    output wire                       de_out,
    output wire [7:0]                 r_out,
    output wire [7:0]                 g_out,
    output wire [7:0]                 b_out,

    output wire                       eth_rst_n_0,
    input  wire                       eth_rgmii_rxc_0,
    input  wire                       eth_rgmii_rx_ctl_0,
    input  wire [3:0]                 eth_rgmii_rxd_0,
    output wire                       eth_rgmii_txc_0,
    output wire                       eth_rgmii_tx_ctl_0,
    output wire [3:0]                 eth_rgmii_txd_0,

    input  wire                       uart_rx,
    output wire                       uart_tx
);

    wire rstn_out; // Internal HDMI/DDR startup reset; G25 belongs to the PHY.
    wire cfg_clk;
    wire locked;
    wire cfg_locked;
    wire core_clk;
    wire clk_125Mhz;
    wire config_reset;
    wire [7:0]   uart_frame_cmd;
    wire [7:0]   uart_frame_len;
    wire [2047:0] uart_frame_data;
    wire          uart_frame_valid;
    wire          uart_frame_error;
    // PLL lock asserts reset asynchronously on startup or loss of lock.
    // ud_reset releases it synchronously in each destination clock domain.
    wire pll_ready = locked && cfg_locked;

    wire key_reset;
    wire correction_enabled;
    wire dehaze_enabled;
    wire gamma_enabled;
    wire he_enabled;

    ud_reset key_reset_sync(
        sys_clk,
        pll_ready,
        key_reset
    );

    ud_key_toggle #(
        .DEBOUNCE_CYCLES(KEY_DEBOUNCE_CYCLES),
        .KEY_ACTIVE_LOW(KEY_ACTIVE_LOW),
        .LED_ACTIVE_LOW(LED_ACTIVE_LOW)
    ) key_control (
        .clk(sys_clk),
        .rst_n(key_reset),
        .key(key[0]),
        .enabled(correction_enabled),
        .led(heart_beat_led)
    );

    ud_key_toggle #(
        .DEBOUNCE_CYCLES(KEY_DEBOUNCE_CYCLES),
        .KEY_ACTIVE_LOW(KEY_ACTIVE_LOW)
    ) dehaze_key_control (
        .clk(sys_clk), .rst_n(key_reset), .key(key[1]),
        .enabled(dehaze_enabled), .led()
    );

    ud_key_toggle #(
        .DEBOUNCE_CYCLES(KEY_DEBOUNCE_CYCLES),
        .KEY_ACTIVE_LOW(KEY_ACTIVE_LOW)
    ) gamma_key_control (
        .clk(sys_clk), .rst_n(key_reset), .key(key[2]),
        .enabled(gamma_enabled), .led()
    );

    ud_key_toggle #(
        .DEBOUNCE_CYCLES(KEY_DEBOUNCE_CYCLES),
        .KEY_ACTIVE_LOW(KEY_ACTIVE_LOW)
    ) he_key_control (
        .clk(sys_clk), .rst_n(key_reset), .key(key[3]),
        .enabled(he_enabled), .led()
    );

    reg [15:0] startup;

    pll pll_gen_clk(
        .clkin1(sys_clk),
        .clkout0(pix_clk),
        .lock(locked)
    );

    cfg_pll cfg_pll_inst(
        .clkin1(sys_clk),
        .clkout0(cfg_clk),
        .lock(cfg_locked)
    );

    ud_reset config_reset_sync(
        cfg_clk,
        pll_ready,
        config_reset
    );

    always @(posedge cfg_clk or negedge config_reset) begin
        if (!config_reset)
            startup <= 0;
        else if (startup != 16'h2710)
            startup <= startup + 1;
    end

    assign rstn_out = config_reset && startup == 16'h2710;

    // 27 MHz / 234 is approximately 115200 baud; reset is synced to sys_clk.
    uart_top #(
        .BPS_NUM(234)
    ) uart_top_inst (
        .clk(sys_clk),
        .rst_n(key_reset),
        .uart_rx(uart_rx),
        .uart_tx(uart_tx),
        .frame_cmd(uart_frame_cmd),
        .frame_len(uart_frame_len),
        .frame_data(uart_frame_data),
        .frame_valid(uart_frame_valid),
        .frame_error(uart_frame_error)
    );

    ms72xx_ctl ms72xx_ctl (
        .clk(cfg_clk),
        .rst_n(rstn_out),
        .init_over_rx(init_over_rx),
        .init_over(hdmi_int_led),
        .iic_scl(hd_scl),
        .iic_sda(hd_sda)
    );

    GTP_INBUFGDS #(
        .IOSTANDARD("DEFAULT"),
        .TERM_DIFF("ON")
    ) u_gtp (
        .O(clk_125Mhz),
        .I(clk_p),
        .IB(clk_n)
    );

    wire [27:0] awaddr;
    wire [27:0] araddr;
    wire [3:0]  awlen;
    wire [3:0]  arlen;
    wire [3:0]  arid;
    wire [3:0]  rid;

    wire awvalid;
    wire awready;
    wire wready;
    wire wlast;
    wire arvalid;
    wire arready;
    wire rvalid;
    wire rlast;

    wire [255:0] wdata;
    wire [255:0] rdata;
    wire [31:0]  wstrb;
    wire [23:0] ddr_rgb;
    wire ddr_hs;
    wire ddr_vs;
    wire ddr_de;
    wire dehaze_rst_n;
    wire [23:0] dehazed_rgb;
    wire [23:0] selected_rgb;
    wire selected_vs, selected_hs, selected_de;
    wire [23:0] gamma_rgb;
    wire gamma_vs, gamma_hs, gamma_de;
    wire [23:0] he_rgb;

    wire pipeline_error;
    wire [31:0] dropped_frames;
    wire [31:0] processing_cycles;

    wire pipeline_reset = rstn_out && ddr_init_done;
    wire net_frame_request, net_frame_valid, net_frame_release;
    wire net_read_request, net_read_ready, net_read_data_valid;
    wire [31:0] net_read_offset;
    wire [255:0] net_read_data;

    ud_reset dehaze_reset_sync(pix_clk, pipeline_reset, dehaze_rst_n);

    ud_system #(
        .ROM_FILE("source/undistort/rom/map.hex")
    ) correction (
        .clk(core_clk),
        .arst_n(pipeline_reset),
        .pclk(pixclk_in),
        .oclk(pix_clk),
        .vin_vs(vs_in),
        .vin_de(de_in),
        .red(r_in),
        .green(g_in),
        .blue(b_in),
        .vout_hs(ddr_hs),
        .vout_vs(ddr_vs),
        .vout_de(ddr_de),
        .rgb(ddr_rgb),
        .axi_awaddr(awaddr),
        .axi_awlen(awlen),
        .axi_awvalid(awvalid),
        .axi_awready(awready),
        .axi_wdata(wdata),
        .axi_wstrb(wstrb),
        .axi_wready(wready),
        .axi_wlast(wlast),
        .axi_araddr(araddr),
        .axi_arlen(arlen),
        .axi_arid(arid),
        .axi_arvalid(arvalid),
        .axi_arready(arready),
        .axi_rdata(rdata),
        .axi_rid(rid),
        .axi_rvalid(rvalid),
        .axi_rlast(rlast),
        .error(pipeline_error),
        .dropped_frames(dropped_frames),
        .processing_cycles(processing_cycles),
        .correction_enable(correction_enabled),
        .net_frame_request(net_frame_request), .net_frame_valid(net_frame_valid),
        .net_frame_sequence(), .net_frame_release(net_frame_release),
        .net_read_request(net_read_request), .net_read_ready(net_read_ready),
        .net_read_offset(net_read_offset), .net_read_data_valid(net_read_data_valid),
        .net_read_data(net_read_data)
    );

    DCP_dehaze #(.IMAGE_WIDTH(1920), .T_MIN(38), .A_INIT(8'd255)) ddr_result_dehaze (
        .clk(pix_clk), .rst_n(dehaze_rst_n),
        .vsync_in(ddr_vs), .hsync_in(ddr_hs), .de_in(ddr_de), .pix_in_I(ddr_rgb),
        .vsync_out(selected_vs), .hsync_out(selected_hs), .de_out(selected_de),
        .pix_out_J(dehazed_rgb), .A_now()
    );

    dcp_output_select dehaze_select (
        .clk(pix_clk), .rst_n(dehaze_rst_n), .enable_async(dehaze_enabled),
        .vsync_out(selected_vs), .raw_rgb(ddr_rgb), .dehazed_rgb(dehazed_rgb),
        .rgb_out(selected_rgb)
    );

    gamma_video gamma_stage (
        .clk(pix_clk), .rst_n(dehaze_rst_n), .enable_async(gamma_enabled),
        .vs_in(selected_vs), .hs_in(selected_hs), .de_in(selected_de),
        .rgb_in(selected_rgb), .vs_out(gamma_vs), .hs_out(gamma_hs),
        .de_out(gamma_de), .rgb_out(gamma_rgb)
    );

    he_video #(.IMAGE_WIDTH(1920), .IMAGE_HEIGHT(1080)) he_stage (
        .clk(pix_clk), .rst_n(dehaze_rst_n), .enable_async(he_enabled),
        .vs_in(gamma_vs), .hs_in(gamma_hs), .de_in(gamma_de), .rgb_in(gamma_rgb),
        .vs_out(vs_out), .hs_out(hs_out), .de_out(de_out), .rgb_out(he_rgb)
    );

    assign r_out = he_rgb[23:16];
    assign g_out = he_rgb[15:8];
    assign b_out = he_rgb[7:0];

    // PHY reset must not depend on its own RX-clock PLL lock.
    assign eth_rst_n_0 = rstn_out;
    eth_ddr_video #(
        .W(1920), .H(1080),
        .LOCAL_MAC(ETH_LOCAL_MAC), .LOCAL_IP(ETH_LOCAL_IP),
        .LOCAL_PORT(ETH_LOCAL_PORT), .DEST_IP(ETH_DEST_IP), .DEST_PORT(ETH_DEST_PORT)
    ) ddr_result_ethernet (
        .clk(core_clk), .arst_n(pipeline_reset),
        .frame_request(net_frame_request), .frame_valid(net_frame_valid),
        .frame_release(net_frame_release),
        .read_request(net_read_request), .read_ready(net_read_ready),
        .read_offset(net_read_offset), .read_data_valid(net_read_data_valid),
        .read_data(net_read_data),
        .rgmii_rxc(eth_rgmii_rxc_0), .rgmii_rx_ctl(eth_rgmii_rx_ctl_0),
        .rgmii_rxd(eth_rgmii_rxd_0), .rgmii_txc(eth_rgmii_txc_0),
        .rgmii_tx_ctl(eth_rgmii_tx_ctl_0), .rgmii_txd(eth_rgmii_txd_0)
    );
   

    ddr3_test u_ddr3_test_h (
        .ref_clk(clk_125Mhz),
        .resetn(rstn_out),
        .core_clk(core_clk),
        .ddr_init_done(ddr_init_done),
        .pll_lock(),
        .phy_pll_lock(),
        .gpll_lock(),
        .rst_gpll_lock(),
        .ddrphy_cpd_lock(),
        .axi_awaddr(awaddr),
        .axi_awuser_ap(1'b0),
        .axi_awuser_id(4'd0),
        .axi_awlen(awlen),
        .axi_awready(awready),
        .axi_awvalid(awvalid),
        .axi_wdata(wdata),
        .axi_wstrb(wstrb),
        .axi_wready(wready),
        .axi_wusero_id(),
        .axi_wusero_last(wlast),
        .axi_araddr(araddr),
        .axi_aruser_ap(1'b0),
        .axi_aruser_id(arid),
        .axi_arlen(arlen),
        .axi_arready(arready),
        .axi_arvalid(arvalid),
        .axi_rdata(rdata),
        .axi_rid(rid),
        .axi_rlast(rlast),
        .axi_rvalid(rvalid),
        .apb_clk(1'b0),
        .apb_rst_n(1'b1),
        .apb_sel(1'b0),
        .apb_enable(1'b0),
        .apb_addr(8'd0),
        .apb_write(1'b0),
        .apb_ready(),
        .apb_wdata(16'd0),
        .apb_rdata(),
        .mem_rst_n(mem_rst_n),
        .mem_ck(mem_ck),
        .mem_ck_n(mem_ck_n),
        .mem_cke(mem_cke),
        .mem_cs_n(mem_cs_n),
        .mem_ras_n(mem_ras_n),
        .mem_cas_n(mem_cas_n),
        .mem_we_n(mem_we_n),
        .mem_odt(mem_odt),
        .mem_a(mem_a),
        .mem_ba(mem_ba),
        .mem_dqs(mem_dqs),
        .mem_dqs_n(mem_dqs_n),
        .mem_dq(mem_dq),
        .mem_dm(mem_dm),
        .dbg_gate_start(1'b0),
        .dbg_cpd_start(1'b0),
        .dbg_ddrphy_rst_n(1'b1),
        .dbg_gpll_scan_rst(1'b0),
        .samp_position_dyn_adj(1'b0),
        .init_samp_position_even(32'd0),
        .init_samp_position_odd(32'd0),
        .wrcal_position_dyn_adj(1'b0),
        .init_wrcal_position(32'd0),
        .force_read_clk_ctrl(1'b0),
        .init_slip_step(16'd0),
        .init_read_clk_ctrl(12'd0),
        .debug_calib_ctrl(),
        .dbg_slice_status(),
        .dbg_slice_state(),
        .debug_data(),
        .dbg_dll_upd_state(),
        .debug_gpll_dps_phase(),
        .dbg_rst_dps_state(),
        .dbg_tran_err_rst_cnt(),
        .dbg_ddrphy_init_fail(),
        .debug_cpd_offset_adj(1'b0),
        .debug_cpd_offset_dir(1'b0),
        .debug_cpd_offset(10'd0),
        .debug_dps_cnt_dir0(),
        .debug_dps_cnt_dir1(),
        .ck_dly_en(1'b0),
        .init_ck_dly_step(8'd0),
        .ck_dly_set_bin(),
        .align_error(),
        .debug_rst_state(),
        .debug_cpd_state()
    );

endmodule

`default_nettype wire
