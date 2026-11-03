`timescale 1ns/1ps
module video_mode_frame_buf #(
    parameter                     MEM_ROW_WIDTH        = 15    ,
    parameter                     MEM_COLUMN_WIDTH     = 10    ,
    parameter                     MEM_BANK_WIDTH       = 3     ,
    parameter                     CTRL_ADDR_WIDTH = MEM_ROW_WIDTH + MEM_BANK_WIDTH + MEM_COLUMN_WIDTH,
    parameter                     MEM_DQ_WIDTH         = 32    ,
    parameter                     H_NUM                = 12'd1920,//12'd1920,
    parameter                     V_NUM                = 12'd1080,//12'd1080,//12'd106,//
    parameter                     PIX_WIDTH            = 16//24 
)(
    input angle_clk,
    input signed [31:0] angle_y_cdeg,
    input rotate_request,
    output rotate_active,
    output video_ready,
    input [11:0] rd_x, rd_y,
    input                         vin_clk,
    input                         wr_fsync,
    input                         wr_en,
    input  [PIX_WIDTH- 1'b1 : 0]  wr_data,
    output                        init_done,
    
    input                         ddr_clk,
    input                         ddr_rstn,
    
    input                         vout_clk,
    input                         rd_fsync,
    input                         rd_en,
    output                        vout_de,
    output [PIX_WIDTH- 1'b1 : 0]  vout_data,
    
    output [CTRL_ADDR_WIDTH-1:0]  axi_awaddr     ,
    output [3:0]                  axi_awid       ,
    output [3:0]                  axi_awlen      ,
    output [2:0]                  axi_awsize     ,
    output [1:0]                  axi_awburst    ,
    input                         axi_awready    ,
    output                        axi_awvalid    ,
                                                  
    output [MEM_DQ_WIDTH*8-1:0]   axi_wdata      ,
    output [MEM_DQ_WIDTH -1 :0]   axi_wstrb      ,
    input                         axi_wlast      ,
    output                        axi_wvalid     ,
    input                         axi_wready     ,
    input  [3 : 0]                axi_bid        ,                                      
                                                  
    output [CTRL_ADDR_WIDTH-1:0]  axi_araddr     ,
    output [3:0]                  axi_arid       ,
    output [3:0]                  axi_arlen      ,
    output [2:0]                  axi_arsize     ,
    output [1:0]                  axi_arburst    ,
    output                        axi_arvalid    ,
    input                         axi_arready    ,
                                                  
    output                        axi_rready     ,
    input  [MEM_DQ_WIDTH*8-1:0]   axi_rdata      ,
    input                         axi_rvalid     ,
    input                         axi_rlast      ,
    input  [3:0]                  axi_rid            
);

    // Stop issuing addresses, drain native DDR completions, then reset clients.
    (* ASYNC_REG="TRUE" *) reg [1:0] request_sync;
    reg selected;
    localparam RUN=0, DRAIN=1, RESET=2;
    reg [1:0] state;
    reg [4:0] reset_count;
    reg [3:0] idle_count;
    reg [7:0] writes_pending, reads_pending;
    reg hold_aw,hold_ar;
    wire allow_aw=ddr_rstn && state!=RESET && (state==RUN || hold_aw);
    wire allow_ar=ddr_rstn && state!=RESET && (state==RUN || hold_ar);
    wire accept_aw=axi_awvalid && axi_awready;
    wire accept_ar=axi_arvalid && axi_arready;
    // Pango native bus reports write completion on controller output wlast.
    wire finish_write=axi_wlast;
    wire finish_read=axi_rvalid && axi_rlast;
    wire normal_reset_n=ddr_rstn && state!=RESET && !selected;
    wire rotate_reset_n=ddr_rstn && state!=RESET && selected;
    assign rotate_active=selected;
    always @(posedge ddr_clk or negedge ddr_rstn) begin
        if(!ddr_rstn) begin
            request_sync<=0; selected<=0; state<=RESET; reset_count<=0;
            writes_pending<=0; reads_pending<=0;
            hold_aw<=0; hold_ar<=0; idle_count<=0;
        end else begin
            request_sync<={request_sync[0],rotate_request};
            hold_aw<=axi_awvalid && !axi_awready;
            hold_ar<=axi_arvalid && !axi_arready;
            case ({accept_aw,finish_write})
                2'b10: writes_pending<=writes_pending+1'b1;
                2'b01: writes_pending<=writes_pending-1'b1;
            endcase
            case ({accept_ar,finish_read})
                2'b10: reads_pending<=reads_pending+1'b1;
                2'b01: reads_pending<=reads_pending-1'b1;
            endcase
            case(state)
                RUN: if(request_sync[1]!=selected) begin state<=DRAIN; idle_count<=0; end
                DRAIN: begin
                    if(writes_pending==0 && reads_pending==0 && !axi_awvalid && !axi_arvalid) begin
                        if(idle_count==7) begin state<=RESET; reset_count<=0; end
                        else idle_count<=idle_count+1'b1;
                    end else idle_count<=0;
                end
                RESET: begin
                    writes_pending<=0; reads_pending<=0; hold_aw<=0; hold_ar<=0;
                    selected<=request_sync[1];
                    if(reset_count==31) begin state<=RUN; reset_count<=0; end
                    else reset_count<=reset_count+1'b1;
                end
                default: state<=RESET;
            endcase
        end
    end
    (* ASYNC_REG="TRUE" *) reg [1:0] ready_sync;
    wire ready_ddr=(state==RUN) && (request_sync[1]==selected) && init_done;
    assign video_ready=ready_sync[1];
    always @(posedge vout_clk or negedge ddr_rstn) begin
        if(!ddr_rstn) ready_sync<=0;
        else ready_sync<={ready_sync[0],ready_ddr};
    end
    wire  n_init_done;
    wire  n_vout_de;
    wire [PIX_WIDTH- 1'b1 : 0] n_vout_data;
    wire [CTRL_ADDR_WIDTH-1:0] n_axi_awaddr;
    wire [3:0] n_axi_awid;
    wire [3:0] n_axi_awlen;
    wire [2:0] n_axi_awsize;
    wire [1:0] n_axi_awburst;
    wire  n_axi_awvalid;
    wire [MEM_DQ_WIDTH*8-1:0] n_axi_wdata;
    wire [MEM_DQ_WIDTH -1 :0] n_axi_wstrb;
    wire  n_axi_wvalid;
    wire [CTRL_ADDR_WIDTH-1:0] n_axi_araddr;
    wire [3:0] n_axi_arid;
    wire [3:0] n_axi_arlen;
    wire [2:0] n_axi_arsize;
    wire [1:0] n_axi_arburst;
    wire  n_axi_arvalid;
    wire  n_axi_rready;
    wire  r_init_done;
    wire  r_vout_de;
    wire [PIX_WIDTH- 1'b1 : 0] r_vout_data;
    wire [CTRL_ADDR_WIDTH-1:0] r_axi_awaddr;
    wire [3:0] r_axi_awid;
    wire [3:0] r_axi_awlen;
    wire [2:0] r_axi_awsize;
    wire [1:0] r_axi_awburst;
    wire  r_axi_awvalid;
    wire [MEM_DQ_WIDTH*8-1:0] r_axi_wdata;
    wire [MEM_DQ_WIDTH -1 :0] r_axi_wstrb;
    wire  r_axi_wvalid;
    wire [CTRL_ADDR_WIDTH-1:0] r_axi_araddr;
    wire [3:0] r_axi_arid;
    wire [3:0] r_axi_arlen;
    wire [2:0] r_axi_arsize;
    wire [1:0] r_axi_arburst;
    wire  r_axi_arvalid;
    wire  r_axi_rready;
    assign init_done=(selected ? r_init_done:n_init_done);
    assign vout_de=(selected ? r_vout_de:n_vout_de);
    assign vout_data=(selected ? r_vout_data:n_vout_data);
    assign axi_awaddr=(selected ? r_axi_awaddr:n_axi_awaddr);
    assign axi_awid=(selected ? r_axi_awid:n_axi_awid);
    assign axi_awlen=(selected ? r_axi_awlen:n_axi_awlen);
    assign axi_awsize=(selected ? r_axi_awsize:n_axi_awsize);
    assign axi_awburst=(selected ? r_axi_awburst:n_axi_awburst);
    assign axi_awvalid=allow_aw && (selected ? r_axi_awvalid:n_axi_awvalid);
    assign axi_wdata=(selected ? r_axi_wdata:n_axi_wdata);
    assign axi_wstrb=(selected ? r_axi_wstrb:n_axi_wstrb);
    assign axi_wvalid=(selected ? r_axi_wvalid:n_axi_wvalid);
    assign axi_araddr=(selected ? r_axi_araddr:n_axi_araddr);
    assign axi_arid=(selected ? r_axi_arid:n_axi_arid);
    assign axi_arlen=(selected ? r_axi_arlen:n_axi_arlen);
    assign axi_arsize=(selected ? r_axi_arsize:n_axi_arsize);
    assign axi_arburst=(selected ? r_axi_arburst:n_axi_arburst);
    assign axi_arvalid=allow_ar && (selected ? r_axi_arvalid:n_axi_arvalid);
    assign axi_rready=(selected ? r_axi_rready:n_axi_rready);
    // Never begin normal capture in the middle of an input frame after reset.
    reg normal_capture_armed;
    always @(posedge vin_clk or negedge normal_reset_n) begin
        if(!normal_reset_n) normal_capture_armed<=0;
        else if(wr_fsync) normal_capture_armed<=1;
    end
    fram_buf #(.MEM_ROW_WIDTH(MEM_ROW_WIDTH),.MEM_COLUMN_WIDTH(MEM_COLUMN_WIDTH),.MEM_BANK_WIDTH(MEM_BANK_WIDTH),.CTRL_ADDR_WIDTH(CTRL_ADDR_WIDTH),.MEM_DQ_WIDTH(MEM_DQ_WIDTH),.H_NUM(H_NUM),.V_NUM(V_NUM),.PIX_WIDTH(PIX_WIDTH)) u_n(
        .vin_clk(vin_clk),
        .wr_fsync(wr_fsync),
        .wr_en(wr_en && normal_capture_armed),
        .wr_data(wr_data),
        .init_done(n_init_done),
        .ddr_clk(ddr_clk),
        .ddr_rstn(normal_reset_n),
        .vout_clk(vout_clk),
        .rd_fsync(rd_fsync),
        .rd_en(rd_en),
        .vout_de(n_vout_de),
        .vout_data(n_vout_data),
        .axi_awaddr(n_axi_awaddr),
        .axi_awid(n_axi_awid),
        .axi_awlen(n_axi_awlen),
        .axi_awsize(n_axi_awsize),
        .axi_awburst(n_axi_awburst),
        .axi_awready(axi_awready && (!selected && allow_aw)),
        .axi_awvalid(n_axi_awvalid),
        .axi_wdata(n_axi_wdata),
        .axi_wstrb(n_axi_wstrb),
        .axi_wlast(axi_wlast && (!selected)),
        .axi_wvalid(n_axi_wvalid),
        .axi_wready(axi_wready && (!selected)),
        .axi_bid(axi_bid),
        .axi_araddr(n_axi_araddr),
        .axi_arid(n_axi_arid),
        .axi_arlen(n_axi_arlen),
        .axi_arsize(n_axi_arsize),
        .axi_arburst(n_axi_arburst),
        .axi_arvalid(n_axi_arvalid),
        .axi_arready(axi_arready && (!selected && allow_ar)),
        .axi_rready(n_axi_rready),
        .axi_rdata(axi_rdata),
        .axi_rvalid(axi_rvalid && (!selected)),
        .axi_rlast(axi_rlast && (!selected)),
        .axi_rid(axi_rid)
    );
    // Capture central 960x540; render 1280x720 centered in the 1080p output.
    rotate_frame_buf #(.MEM_ROW_WIDTH(MEM_ROW_WIDTH),.MEM_COLUMN_WIDTH(MEM_COLUMN_WIDTH),.MEM_BANK_WIDTH(MEM_BANK_WIDTH),.CTRL_ADDR_WIDTH(CTRL_ADDR_WIDTH),.MEM_DQ_WIDTH(MEM_DQ_WIDTH),.H_NUM(H_NUM),.V_NUM(V_NUM),.PIX_WIDTH(PIX_WIDTH),.CROP_WIDTH(960),.CROP_HEIGHT(540),.OUT_WIDTH(H_NUM),.OUT_HEIGHT(V_NUM),.RENDER_WIDTH(1280),.RENDER_HEIGHT(720)) u_r(
        .vin_clk(vin_clk),
        .wr_fsync(wr_fsync),
        .wr_en(wr_en),
        .wr_data(wr_data),
        .init_done(r_init_done),
        .ddr_clk(ddr_clk),
        .ddr_rstn(rotate_reset_n),
        .vout_clk(vout_clk),
        .rd_fsync(rd_fsync),
        .rd_en(rd_en),
        .vout_de(r_vout_de),
        .vout_data(r_vout_data),
        .axi_awaddr(r_axi_awaddr),
        .axi_awid(r_axi_awid),
        .axi_awlen(r_axi_awlen),
        .axi_awsize(r_axi_awsize),
        .axi_awburst(r_axi_awburst),
        .axi_awready(axi_awready && (selected && allow_aw)),
        .axi_awvalid(r_axi_awvalid),
        .axi_wdata(r_axi_wdata),
        .axi_wstrb(r_axi_wstrb),
        .axi_wlast(axi_wlast && (selected)),
        .axi_wvalid(r_axi_wvalid),
        .axi_wready(axi_wready && (selected)),
        .axi_bid(axi_bid),
        .axi_araddr(r_axi_araddr),
        .axi_arid(r_axi_arid),
        .axi_arlen(r_axi_arlen),
        .axi_arsize(r_axi_arsize),
        .axi_arburst(r_axi_arburst),
        .axi_arvalid(r_axi_arvalid),
        .axi_arready(axi_arready && (selected && allow_ar)),
        .axi_rready(r_axi_rready),
        .axi_rdata(axi_rdata),
        .axi_rvalid(axi_rvalid && (selected)),
        .axi_rlast(axi_rlast && (selected)),
        .axi_rid(axi_rid),
        .angle_clk(angle_clk),
        .angle_y_cdeg(angle_y_cdeg),
        .rd_x(rd_x),
        .rd_y(rd_y)
    );
endmodule
