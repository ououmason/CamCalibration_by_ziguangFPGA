`timescale 1ns / 1ps
module HDMI_IN_DDR3_HDMI_OUT_top#(
	parameter MEM_ROW_ADDR_WIDTH   = 15         ,
	parameter MEM_COL_ADDR_WIDTH   = 10         ,
	parameter MEM_BADDR_WIDTH      = 3          ,
	parameter MEM_DQ_WIDTH         =  32        ,
	parameter MEM_DQS_WIDTH        =  32/8       ,
    parameter CNN_LED_ACTIVE_LOW  = 1'b1,
    parameter OSD_LED_ACTIVE_LOW  = 1'b1
)(
	input                                sys_clk              ,//27Mhz
    input                                clk_p ,
    input                                clk_n ,
    input                                rst_in ,
    input                                key2 , // Active-low OSD toggle, C23.
    input                                key_rotate, // Active-low mode toggle, B22.
    input                                uart_rx,
    output                               uart_tx,

//DDR
    output                               mem_rst_n                 ,
    output                               mem_ck                    ,
    output                               mem_ck_n                  ,
    output                               mem_cke                   ,
    output                               mem_cs_n                  ,
    output                               mem_ras_n                 ,
    output                               mem_cas_n                 ,
    output                               mem_we_n                  ,
    output                               mem_odt                   ,
    output      [MEM_ROW_ADDR_WIDTH-1:0] mem_a                     ,
    output      [MEM_BADDR_WIDTH-1:0]    mem_ba                    ,
    inout       [MEM_DQ_WIDTH/8-1:0]     mem_dqs                   ,
    inout       [MEM_DQ_WIDTH/8-1:0]     mem_dqs_n                 ,
    inout       [MEM_DQ_WIDTH-1:0]       mem_dq                    ,
    output      [MEM_DQ_WIDTH/8-1:0]     mem_dm                    ,
    output reg                           heart_beat_led            ,
    output                               ddr_init_done             ,
    output                               init_over_rx              ,
//MS72xx       
    output                               rstn_out                  ,
    output                               hd_scl                ,
    inout                                hd_sda                ,
    output                               hdmi_int_led              ,//HDMI_OUT初始化完成

    //HDMI_in
    input             pixclk_in    ,                            
    input             vs_in    /*synthesis PAP_MARK_DEBUG="1"*/, 
    input             hs_in    /*synthesis PAP_MARK_DEBUG="1"*/, 
    input             de_in    /*synthesis PAP_MARK_DEBUG="1"*/,
    input     [7:0]   r_in    /*synthesis PAP_MARK_DEBUG="1"*/, 
    input     [7:0]   g_in    /*synthesis PAP_MARK_DEBUG="1"*/, 
    input     [7:0]   b_in    /*synthesis PAP_MARK_DEBUG="1"*/, 
//HDMI_OUT
    output                               pix_clk   /*synthesis PAP_MARK_DEBUG="1"*/                ,//pixclk                           
    output    reg                           vs_out    /*synthesis PAP_MARK_DEBUG="1"*/                , 
    output    reg                           hs_out    /*synthesis PAP_MARK_DEBUG="1"*/                , 
    output    reg                           de_out    /*synthesis PAP_MARK_DEBUG="1"*/                ,
    output    reg    [7:0]                  r_out     /*synthesis PAP_MARK_DEBUG="1"*/                , 
    output    reg    [7:0]                  g_out     /*synthesis PAP_MARK_DEBUG="1"*/                , 
    output    reg    [7:0]                  b_out     /*synthesis PAP_MARK_DEBUG="1"*/    
);
/////////////////////////////////////////////////////////////////////////////////////
// ENABLE_DDR
    parameter CTRL_ADDR_WIDTH = MEM_ROW_ADDR_WIDTH + MEM_BADDR_WIDTH + MEM_COL_ADDR_WIDTH;//28
    parameter TH_1S = 27'd33000000;
/////////////////////////////////////////////////////////////////////////////////////
    reg  [15:0]                 rstn_1ms            ;
    wire[15:0]                  o_rgb565            ;
    wire                        ddr_cal_done;

//axi bus   
    wire [CTRL_ADDR_WIDTH-1:0]  axi_awaddr                 ;
    wire                        axi_awuser_ap              ;
    wire [3:0]                  axi_awuser_id              ;
    wire [3:0]                  axi_awlen                  ;
    wire                        axi_awready                ;/*synthesis PAP_MARK_DEBUG="1"*/
    wire                        axi_awvalid                ;/*synthesis PAP_MARK_DEBUG="1"*/
    wire [MEM_DQ_WIDTH*8-1:0]   axi_wdata                  ;
    wire [MEM_DQ_WIDTH*8/8-1:0] axi_wstrb                  ;
    wire                        axi_wready                 ;/*synthesis PAP_MARK_DEBUG="1"*/
    wire [3:0]                  axi_wusero_id              ;
    wire                        axi_wusero_last            ;
    wire [CTRL_ADDR_WIDTH-1:0]  axi_araddr                 ;
    wire                        axi_aruser_ap              ;
    wire [3:0]                  axi_aruser_id              ;
    wire [3:0]                  axi_arlen                  ;
    wire                        axi_arready                ;/*synthesis PAP_MARK_DEBUG="1"*/
    wire                        axi_arvalid                ;/*synthesis PAP_MARK_DEBUG="1"*/
    wire [MEM_DQ_WIDTH*8-1:0]   axi_rdata                   /* synthesis syn_keep = 1 */;
    wire                        axi_rvalid                  /* synthesis syn_keep = 1 */;
    wire [3:0]                  axi_rid                    ;
    wire                        axi_rlast                  ;
    reg  [15:0]                 cnt_1                      ;
/////////////////////////////////////////////////////////////////////////////////////
//PLL
pll pll_gen_clk (
    .clkin1   (  sys_clk    ),//27MHz
    .clkout0  (  pix_clk    ),//148.5

    .lock (  locked     )
);


cfg_pll cfg_pll_inst (
  .clkout0(cfg_clk),    // output
  .lock(),          // output
  .clkin1(sys_clk)       // input
);




ms72xx_ctl ms72xx_ctl(
    .clk         (  cfg_clk    ), //input       clk,
    .rst_n       (  rstn_out   ), //input       rstn,
           
    .init_over_rx(  rx_init_done),                 
    .init_over   (  init_over  ), //output      init_over,
    .iic_scl     (  hd_scl    ), //output      iic_scl,
    .iic_sda     (  hd_sda    )  //inout       iic_sda
);
    assign   init_over_rx = rx_init_done;
   assign    hdmi_int_led    =    init_over; 
    
    always @(posedge cfg_clk)
    begin
    	if(!locked)
    	    rstn_1ms <= 16'd0;
    	else
    	begin
    		if(rstn_1ms == 16'h2710)
    		    rstn_1ms <= rstn_1ms;
    		else
    		    rstn_1ms <= rstn_1ms + 1'b1;
    	end
    end
    



    reg    rstn_d0;
    reg    rstn_d1;




    assign rstn_out = (rstn_1ms == 16'h2710);


wire    [15:0]    hdmi_data_in;
assign    hdmi_data_in = {r_in[7:3],g_in[7:2],b_in[7:3]};


wire    vs_reg;
wire    hs_reg;
wire    rd_en ;
wire signed [31:0] angle_y_cdeg;
wire angle_valid,angle_error;
wire rotate_active_ddr,mode_video_ready;
reg rotate_enable_request;
wire [11:0] act_x,act_y;
// C22 is the existing enhancement key, so UART reset must not depend on it.
(* ASYNC_REG="TRUE" *) reg [1:0] uart_reset_pipe;
always @(posedge sys_clk or negedge rstn_out) begin
    if(!rstn_out) uart_reset_pipe<=0;
    else uart_reset_pipe<={uart_reset_pipe[0],1'b1};
end
uart_top u_uart_angle(.clk(sys_clk),.rst_n(uart_reset_pipe[1]),
    .uart_rx(uart_rx),.uart_tx(uart_tx),.angle_y_cdeg(angle_y_cdeg),
    .angle_valid(angle_valid),.angle_error(angle_error));



//////////////////////////////////////////////////////////////////////////////////////////////////////////
//修改ddr读写模块v1
    video_mode_frame_buf fram_buf(
        .angle_clk(sys_clk),.angle_y_cdeg(-angle_y_cdeg),
        .rotate_request(rotate_enable_request),.rotate_active(rotate_active_ddr),
        .video_ready(mode_video_ready),.rd_x(act_x),.rd_y(act_y),
        .ddr_clk        (  core_clk             ),//input                         ddr_clk,
        .ddr_rstn       (  ddr_cal_done         ),//input                         ddr_rstn,
        //data_in                                  
        .vin_clk        (  pixclk_in         ),//input                         vin_clk,
        .wr_fsync       (  ~vs_in           ),//input                         wr_fsync,
        .wr_en          (  de_in           ),//input                         wr_en,
        .wr_data        (  hdmi_data_in             ),//input  [15 : 0]  wr_data,
        //data_out
        .vout_clk       (  pix_clk              ),//input                         vout_clk,
        .rd_fsync       (  vs_reg               ),//input                         rd_fsync,
        .rd_en          (  rd_en                ),//input                         rd_en,
        .vout_de        (  de_o               ),//output                        vout_de,
        .vout_data      (  o_rgb565             ),//output [PIX_WIDTH- 1'b1 : 0]  vout_data,
        .init_done      (  init_done            ),//output reg                    init_done,
        //axi bus
        .axi_awaddr     (  axi_awaddr           ),// output[27:0]
        .axi_awid       (  axi_awuser_id        ),// output[3:0]
        .axi_awlen      (  axi_awlen            ),// output[3:0]
        .axi_awsize     (                       ),// output[2:0]
        .axi_awburst    (                       ),// output[1:0]
        .axi_awready    (  axi_awready          ),// input
        .axi_awvalid    (  axi_awvalid          ),// output               
        .axi_wdata      (  axi_wdata            ),// output[255:0]
        .axi_wstrb      (  axi_wstrb            ),// output[31:0]
        .axi_wlast      (  axi_wusero_last      ),// input
        .axi_wvalid     (                       ),// output
        .axi_wready     (  axi_wready           ),// input
        .axi_bid        (  4'd0                 ),// input[3:0]
        .axi_araddr     (  axi_araddr           ),// output[27:0]
        .axi_arid       (  axi_aruser_id        ),// output[3:0]
        .axi_arlen      (  axi_arlen            ),// output[3:0]
        .axi_arsize     (                       ),// output[2:0]
        .axi_arburst    (                       ),// output[1:0]
        .axi_arvalid    (  axi_arvalid          ),// output
        .axi_arready    (  axi_arready          ),// input
        .axi_rready     (                       ),// output
        .axi_rdata      (  axi_rdata            ),// input[255:0]
        .axi_rvalid     (  axi_rvalid           ),// input
        .axi_rlast      (  axi_rlast            ),// input
        .axi_rid        (  axi_rid              ) // input[3:0]         
    );

   /*  always@(posedge pix_clk) begin
        r_out<=8'hff;
        g_out<=8'hff;
        b_out<=8'h00; 
        vs_out<=vs_o;
        hs_out<=hs_o;
        de_out<=de_re;
     end*/
//assign pix_clk = pixclk_in;
// Zero-DCE++ integration. All existing DDR/HDMI pins and IP instances retain
// their names. Only the final video-output datapath is replaced in this top.
// The existing active-low button is an enhancement toggle, not video reset.
// C18 retains its constrained port name but now drives the OSD LED only.
// The DDR IP status is a separate internal net and never depends on KEY2.
wire cnn_reset_async_n = ddr_cal_done & locked;
(* ASYNC_REG="TRUE" *) reg [1:0] cnn_reset_pipe;
always @(posedge pix_clk or negedge cnn_reset_async_n) begin
    if (!cnn_reset_async_n) cnn_reset_pipe <= 2'b00;
    else cnn_reset_pipe <= {cnn_reset_pipe[0],1'b1};
end
// 20 ms stable press/release at 148.5 MHz; long presses toggle only once.
(* ASYNC_REG="TRUE" *) reg [1:0] cnn_key_sync;
reg cnn_key_level;
reg [21:0] cnn_key_count;
reg cnn_enable_request;
always @(posedge pix_clk) begin
    if (!cnn_reset_pipe[1]) begin
        cnn_key_sync <= 2'b11;
        cnn_key_level <= 1'b1;
        cnn_key_count <= 22'd0;
        cnn_enable_request <= 1'b0;
    end else begin
        cnn_key_sync <= {cnn_key_sync[0],rst_in};
        if (cnn_key_sync[1] == cnn_key_level)
            cnn_key_count <= 22'd0;
        else if (cnn_key_count == 22'd2969999) begin
            cnn_key_count <= 22'd0;
            cnn_key_level <= cnn_key_sync[1];
            if (!cnn_key_sync[1]) cnn_enable_request <= ~cnn_enable_request;
        end else cnn_key_count <= cnn_key_count + 1'b1;
    end
end
(* ASYNC_REG="TRUE" *) reg [1:0] osd_key_sync;
reg osd_key_level;
reg [21:0] osd_key_count;
reg osd_enable_request;
always @(posedge pix_clk) begin
    if (!cnn_reset_pipe[1]) begin
        osd_key_sync<=2'b11; osd_key_level<=1'b1;
        osd_key_count<=0; osd_enable_request<=0;
    end else begin
        osd_key_sync<={osd_key_sync[0],key2};
        if (osd_key_sync[1]==osd_key_level) osd_key_count<=0;
        else if (osd_key_count==22'd2969999) begin
            osd_key_count<=0; osd_key_level<=osd_key_sync[1];
            if (!osd_key_sync[1]) osd_enable_request<=~osd_enable_request;
        end else osd_key_count<=osd_key_count+1'b1;
    end
end
// B22: synchronize, debounce both edges for 20 ms, toggle once per press.
(* ASYNC_REG="TRUE" *) reg [1:0] rotate_key_sync;
reg rotate_key_level;
reg [21:0] rotate_key_count;

(* ASYNC_REG="TRUE" *) reg [1:0] rotate_active_sync;
reg rotate_frame;
reg mode_vs_d;
reg video_frame_ready;
always @(posedge pix_clk) begin
    if(!cnn_reset_pipe[1]) begin
        rotate_key_sync<=2'b11; rotate_key_level<=1;
        rotate_key_count<=0; rotate_enable_request<=0;
        rotate_active_sync<=0; rotate_frame<=0; mode_vs_d<=0;
        video_frame_ready<=0;
    end else begin
        rotate_key_sync<={rotate_key_sync[0],key_rotate};
        if(rotate_key_sync[1]==rotate_key_level) rotate_key_count<=0;
        else if(rotate_key_count==22'd2969999) begin
            rotate_key_count<=0; rotate_key_level<=rotate_key_sync[1];
            if(!rotate_key_sync[1]) rotate_enable_request<=~rotate_enable_request;
        end else rotate_key_count<=rotate_key_count+1'b1;
        rotate_active_sync<={rotate_active_sync[0],rotate_active_ddr};
        mode_vs_d<=vs_reg;
        // Blank until a complete selected frame is ready, resume at VS only.
        if(!mode_video_ready) video_frame_ready<=0;
        if(vs_reg && !mode_vs_d) begin
            rotate_frame<=rotate_enable_request || rotate_active_sync[1];
            video_frame_ready<=mode_video_ready;
        end
    end
end
wire [15:0] mode_rgb565=video_frame_ready ? o_rgb565:16'd0;
// Keep the original fixed latency video path for both modes. Its CNN and OSD
// are bypassed during rotation; key requests are retained for mode exit.
reg [1:0] full_de_pipe;
always @(posedge pix_clk) begin
    if(!cnn_reset_pipe[1]) full_de_pipe<=0;
    else full_de_pipe<={full_de_pipe[0],rd_en};
end
wire cnn_vs,cnn_hs,cnn_de;
wire [23:0] cnn_rgb;
wire cnn_busy,cnn_curve_ready;
wire cnn_enabled;
wire osd_enabled;
reg osd_led;
assign ddr_init_done=osd_led;
always @(posedge pix_clk) begin
    if (!cnn_reset_pipe[1]) osd_led<=OSD_LED_ACTIVE_LOW;
    else osd_led<=OSD_LED_ACTIVE_LOW ? ~osd_enabled : osd_enabled;
end
wire [31:0] cnn_cycles_last;
wire cnn_range_overflow,cnn_frame_drop;
zdce_ddr_read_adapter u_zero_dce (
    .pix_clk(pix_clk),.rst_n(cnn_reset_pipe[1]),
    .enhance_enable(cnn_enable_request && !rotate_frame),
    .enhance_active(cnn_enabled),
    .overlay_enable(osd_enable_request && !rotate_frame),.overlay_active(osd_enabled),
    .sync_vs(vs_reg),.sync_hs(hs_reg),.vout_de(full_de_pipe[1]),.rgb565(mode_rgb565),
    .vs_out(cnn_vs),.hs_out(cnn_hs),.de_out(cnn_de),.rgb_out(cnn_rgb),
    .cnn_busy(cnn_busy),.curve_ready(cnn_curve_ready),
    .cnn_cycles_last(cnn_cycles_last),
    .range_overflow_sticky(cnn_range_overflow),.frame_drop_sticky(cnn_frame_drop)
);
always @(posedge pix_clk) begin
    if (!cnn_reset_pipe[1]) begin
        vs_out<=0; hs_out<=0; de_out<=0;
        r_out<=0; g_out<=0; b_out<=0;
    end else begin
        vs_out<=cnn_vs; hs_out<=cnn_hs; de_out<=cnn_de;
        r_out<=cnn_rgb[23:16]; g_out<=cnn_rgb[15:8]; b_out<=cnn_rgb[7:0];
    end
end
/////////////////////////////////////////////////////////////////////////////////////
//产生visa时序 
wire                        hs         ;
wire                        vs         ;
wire                        de         ;
//MODE_1080p
parameter V_TOTAL = 12'd1125;  //场扫描周期
parameter V_FP = 12'd4;        //场显示前沿
parameter V_BP = 12'd36;       //场显示后沿
parameter V_SYNC = 12'd5;      //场同步
parameter V_ACT = 12'd1080;    //场有效数据
parameter H_TOTAL = 12'd2200;  //行扫描周期
parameter H_FP = 12'd88;       //行显示前沿
parameter H_BP = 12'd148;      //行显示后沿
parameter H_SYNC = 12'd44;     //行同步
parameter H_ACT = 12'd1920;    //行数据有效
parameter HV_OFFSET = 12'd0;   
parameter   X_WIDTH = 4'd12;
parameter   Y_WIDTH = 4'd12; 

  
sync_vg #(
    .X_BITS               (  X_WIDTH              ), 
    .Y_BITS               (  Y_WIDTH              ),
    .V_TOTAL              (  V_TOTAL              ),//                        
    .V_FP                 (  V_FP                 ),//                        
    .V_BP                 (  V_BP                 ),//                        
    .V_SYNC               (  V_SYNC               ),//                        
    .V_ACT                (  V_ACT                ),//                        
    .H_TOTAL              (  H_TOTAL              ),//                        
    .H_FP                 (  H_FP                 ),//                        
    .H_BP                 (  H_BP                 ),//                        
    .H_SYNC               (  H_SYNC               ),//                        
    .H_ACT                (  H_ACT                ) //                        

) sync_vg                                         
(                                                 
    .clk                  (  pix_clk               ),//input                   clk,                                 
    .rstn                 (  ddr_cal_done                  ),//input                   rstn,
    .vs_out               (  vs_reg                   ),//output reg              vs_out,                                                                                                                                      
    .hs_out               (  hs_reg                   ),//output reg              hs_out,            
    .de_out               (  rd_en                   ),//output reg              de_out,             
    .x_act                (  act_x                ),//output reg [X_BITS-1:0] x_out,             
    .y_act                (  act_y                ) //output reg [Y_BITS:0]   y_out,             
); 


////////////////////////////////////////////////////////////////////////////////////////////

wire clk_125Mhz ;

GTP_INBUFGDS #(
    .IOSTANDARD("DEFAULT"),
    .TERM_DIFF("ON")
) u_gtp (
    .O(clk_125Mhz), // OUTPUT  
    .I(clk_p), // INPUT  
    .IB(clk_n) // INPUT  
);

//ddr    
        ddr3_test u_ddr3_test_h (
             .ref_clk                   (clk_125Mhz            ),
             .resetn                    (rstn_out           ),// input
             .ddr_init_done             (ddr_cal_done       ),// output

             .pll_lock                  (pll_lock           ),// output

             .core_clk                  (core_clk),                                  // output

             .phy_pll_lock              (phy_pll_lock),                          // output
             .gpll_lock                 (gpll_lock),                                // output
             .rst_gpll_lock             (rst_gpll_lock),                        // output
             .ddrphy_cpd_lock           (ddrphy_cpd_lock),                    // output
             //.ddr_init_done             (ddr_init_done),                        // output


             .axi_awaddr                (axi_awaddr         ),// input [27:0]
             .axi_awuser_ap             (1'b0               ),// input
             .axi_awuser_id             (axi_awuser_id      ),// input [3:0]
             .axi_awlen                 (axi_awlen          ),// input [3:0]
             .axi_awready               (axi_awready        ),// output
             .axi_awvalid               (axi_awvalid        ),// input
             .axi_wdata                 (axi_wdata          ),
             .axi_wstrb                 (axi_wstrb          ),// input [31:0]
             .axi_wready                (axi_wready         ),// output
             .axi_wusero_id             (                   ),// output [3:0]
             .axi_wusero_last           (axi_wusero_last    ),// output
             .axi_araddr                (axi_araddr         ),// input [27:0]
             .axi_aruser_ap             (1'b0               ),// input
             .axi_aruser_id             (axi_aruser_id      ),// input [3:0]
             .axi_arlen                 (axi_arlen          ),// input [3:0]
             .axi_arready               (axi_arready        ),// output
             .axi_arvalid               (axi_arvalid        ),// input
             .axi_rdata                 (axi_rdata          ),// output [255:0]
             .axi_rid                   (axi_rid            ),// output [3:0]
             .axi_rlast                 (axi_rlast          ),// output
             .axi_rvalid                (axi_rvalid         ),// output

             .apb_clk                   (1'b0               ),// input
             .apb_rst_n                 (1'b1               ),// input
             .apb_sel                   (1'b0               ),// input
             .apb_enable                (1'b0               ),// input
             .apb_addr                  (8'b0               ),// input [7:0]
             .apb_write                 (1'b0               ),// input
             .apb_ready                 (                   ), // output
             .apb_wdata                 (16'b0              ),// input [15:0]
             .apb_rdata                 (                   ),// output [15:0]
//             .apb_int                   (                   ),// output

             .mem_rst_n                 (mem_rst_n          ),// output
             .mem_ck                    (mem_ck             ),// output
             .mem_ck_n                  (mem_ck_n           ),// output
             .mem_cke                   (mem_cke            ),// output
             .mem_cs_n                  (mem_cs_n           ),// output
             .mem_ras_n                 (mem_ras_n          ),// output
             .mem_cas_n                 (mem_cas_n          ),// output
             .mem_we_n                  (mem_we_n           ),// output
             .mem_odt                   (mem_odt            ),// output
             .mem_a                     (mem_a              ),// output [14:0]
             .mem_ba                    (mem_ba             ),// output [2:0]
             .mem_dqs                   (mem_dqs            ),// inout [3:0]
             .mem_dqs_n                 (mem_dqs_n          ),// inout [3:0]
             .mem_dq                    (mem_dq             ),// inout [31:0]
             .mem_dm                    (mem_dm             ),// output [3:0]
             //debug

  .dbg_gate_start(1'b0),                      // input
  .dbg_cpd_start(1'b0),                        // input
  .dbg_ddrphy_rst_n(1'b1),                  // input
  .dbg_gpll_scan_rst(1'b0),                // input
  .samp_position_dyn_adj(1'b0),        // input
  .init_samp_position_even(32'd0),    // input [31:0]
  .init_samp_position_odd(32'd0),      // input [31:0]
  .wrcal_position_dyn_adj(1'b0),      // input
  .init_wrcal_position(32'd0),            // input [31:0]
  .force_read_clk_ctrl(1'b0),            // input
  .init_slip_step(16'd0),                      // input [15:0]
  .init_read_clk_ctrl(12'd0),              // input [11:0]
  .debug_calib_ctrl(),                  // output [33:0]
  .dbg_slice_status(),                  // output [67:0]
  .dbg_slice_state(),                    // output [87:0]
  .debug_data(),                              // output [275:0]
  .dbg_dll_upd_state(),                // output [1:0]
  .debug_gpll_dps_phase(),          // output [8:0]
  .dbg_rst_dps_state(),                // output [2:0]
  .dbg_tran_err_rst_cnt(),          // output [5:0]
  .dbg_ddrphy_init_fail(),          // output
  .debug_cpd_offset_adj(1'b0),          // input
  .debug_cpd_offset_dir(1'b0),          // input
  .debug_cpd_offset(10'd0),                  // input [9:0]
  .debug_dps_cnt_dir0(),              // output [9:0]
  .debug_dps_cnt_dir1(),              // output [9:0]
  .ck_dly_en(1'b0),                                // input
  .init_ck_dly_step(8'h0),                  // input [7:0]
  .ck_dly_set_bin(),                      // output [7:0]
  .align_error(),                            // output
  .debug_rst_state(),                    // output [3:0]
  .debug_cpd_state()                     // output [3:0]
       );

// Reuse the existing blinking LED pin (A20) as a steady CNN enable indicator.
// DDR calibration remains internal; C18 independently indicates OSD enable.
always @(posedge pix_clk) begin
    if (!cnn_reset_pipe[1]) heart_beat_led <= CNN_LED_ACTIVE_LOW;
    else heart_beat_led <= CNN_LED_ACTIVE_LOW ? ~cnn_enabled : cnn_enabled;
end
                 
/////////////////////////////////////////////////////////////////////////////////////
endmodule
