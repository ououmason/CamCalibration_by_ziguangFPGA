`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: Meyesemi
// Engineer: Nill
// 
// Create Date: 15/03/23 14:17:29
// Design Name: 
// Module Name: fram_buf
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////
`define UD #1
module rotate_frame_buf #(
    parameter                     MEM_ROW_WIDTH        = 15    ,
    parameter                     MEM_COLUMN_WIDTH     = 10    ,
    parameter                     MEM_BANK_WIDTH       = 3     ,
    parameter                     CTRL_ADDR_WIDTH = MEM_ROW_WIDTH + MEM_BANK_WIDTH + MEM_COLUMN_WIDTH,
    parameter                     MEM_DQ_WIDTH         = 32    ,
    parameter                     H_NUM                = 12'd1920,//12'd1920,
    parameter                     V_NUM                = 12'd1080,//12'd1080,//12'd106,//
    parameter                     PIX_WIDTH            = 16,
    // 1080p input: capture x=480..1439, y=270..809 (960x540).
    // Render 1280x720 at output x=320..1599, y=180..899; black surround.
    parameter integer CROP_WIDTH=960, CROP_HEIGHT=540,
    parameter integer OUT_WIDTH=1920, OUT_HEIGHT=1080,
    parameter integer RENDER_WIDTH=1280, RENDER_HEIGHT=720,
    parameter integer ANGLE_UPDATE_CYCLES=450000,
    parameter integer RENDER_INTERVAL_CYCLES=1
)(
    input                         angle_clk,
    input signed [31:0]           angle_y_cdeg,
    input                         vin_clk,
    input                         wr_fsync,
    input                         wr_en,
    input  [PIX_WIDTH- 1'b1 : 0]  wr_data,
    output reg                    init_done=0,
    
    input                         ddr_clk,
    input                         ddr_rstn,
    
    input                         vout_clk,
    input                         rd_fsync,
    input                         rd_en,
    input [11:0]                  rd_x, rd_y,
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
    wire signed [31:0] angle_cos,angle_sin;
    rotate_angle #(.UPDATE_CYCLES(ANGLE_UPDATE_CYCLES)) angle_control(.angle_clk(angle_clk),.clk(ddr_clk),.rst_n(ddr_rstn),
        .angle_y_cdeg(angle_y_cdeg),.cos_q16(angle_cos),.sin_q16(angle_sin));
    // Native addresses count 32-bit words: a 1080p RGB565 destination uses
    // 1,036,800 words, safely inside each existing 2^22-word frame bank.
    localparam FRAME_BITS=22;
    wire capture_enable,display_bank,display_valid,rot_busy;
    reg cap1,cap2,capture_active,vin_vs_d;
    localparam integer IN_X0=(H_NUM-CROP_WIDTH)/2, IN_Y0=(V_NUM-CROP_HEIGHT)/2;
    localparam integer OUT_X0=(OUT_WIDTH-RENDER_WIDTH)/2, OUT_Y0=(OUT_HEIGHT-RENDER_HEIGHT)/2;
    reg [11:0] input_x,input_y;
    reg input_de_d,capture_start_toggle;
    wire crop_write=wr_en && input_x>=IN_X0 && input_x<IN_X0+CROP_WIDTH &&
                              input_y>=IN_Y0 && input_y<IN_Y0+CROP_HEIGHT;
    wire crop_read=rd_en && rd_x>=OUT_X0 && rd_x<OUT_X0+RENDER_WIDTH &&
                            rd_y>=OUT_Y0 && rd_y<OUT_Y0+RENDER_HEIGHT;
    always @(posedge vin_clk or negedge ddr_rstn) begin
        if(!ddr_rstn) begin input_x<=0; input_y<=0; input_de_d<=0; end
        else begin
            input_de_d<=wr_en;
            if(wr_fsync && !vin_vs_d) begin input_x<=0; input_y<=0; end
            else begin
                if(wr_en) input_x<=input_x+1'b1; else input_x<=0;
                if(input_de_d && !wr_en) input_y<=input_y+1'b1;
            end
        end
    end
    always @(posedge vin_clk or negedge ddr_rstn) begin
        if(!ddr_rstn) begin cap1<=0; cap2<=0; capture_active<=0; vin_vs_d<=0; capture_start_toggle<=0; end
        else begin
            cap1<=capture_enable; cap2<=cap1; vin_vs_d<=wr_fsync;
            if(wr_fsync && !vin_vs_d) begin
                capture_active<=cap2;
                if(cap2) capture_start_toggle<=!capture_start_toggle;
            end
        end
    end
    wire [CTRL_ADDR_WIDTH-1:0] wcmd_addr;
    wire [31:0] wcmd_len;
    wire wcmd_en,wcmd_ready,wcmd_done,wdata_req,wr_bac;
    wire [255:0] capture_data;
    wire [5:0] source_count;
    wr_buf #(.ADDR_WIDTH(CTRL_ADDR_WIDTH),.H_NUM(CROP_WIDTH),.V_NUM(CROP_HEIGHT),
        .DQ_WIDTH(32),.LEN_WIDTH(32),.PIX_WIDTH(16),
        .LINE_ADDR_WIDTH(FRAME_BITS),.FRAME_CNT_WIDTH(6)) capture(
        .ddr_clk(ddr_clk),.ddr_rstn(ddr_rstn),.wr_clk(vin_clk),
        .wr_fsync(wr_fsync),.wr_en(crop_write && capture_active),.wr_data(wr_data),
        .rd_bac(wr_bac),.ddr_wreq(wcmd_en),.ddr_waddr(wcmd_addr),
        .ddr_wr_len(wcmd_len),.ddr_wrdy(wcmd_ready),.ddr_wdone(wcmd_done),
        .ddr_wdata(capture_data),.ddr_wdata_req(wdata_req),
        .frame_wcnt(source_count),.frame_wirq());
    reg [11:0] captured_lines;
    reg capture_done,captured_bank;
    reg capture_start1,capture_start2,capture_start3;
    always @(posedge ddr_clk or negedge ddr_rstn) begin
        if(!ddr_rstn) begin captured_lines<=0; capture_done<=0; captured_bank<=0;
            capture_start1<=0; capture_start2<=0; capture_start3<=0; end
        else begin
            capture_start1<=capture_start_toggle; capture_start2<=capture_start1; capture_start3<=capture_start2;
            capture_done<=0;
            if(!capture_enable || capture_start2!=capture_start3) captured_lines<=0;
            else if(wcmd_done) begin
                if(captured_lines==CROP_HEIGHT-1) begin
                    captured_lines<=0; capture_done<=1; captured_bank<=source_count[0];
                end else captured_lines<=captured_lines+1'b1;
            end
        end
    end
    wire [CTRL_ADDR_WIDTH-1:0] c_awaddr,c_araddr;
    wire [3:0] c_awlen,c_arlen;
    wire c_awvalid,c_arvalid,c_arready,c_rvalid;
    wire [255:0] c_wdata;
    wire [31:0] c_wstrb;
    wire c_wvalid;
    wire [CTRL_ADDR_WIDTH-1:0] rcmd_addr;
    wire [31:0] rcmd_len;
    wire rcmd_en,rcmd_ready,rcmd_done,scan_data_en;
    wire [255:0] scan_data;
    wire [CTRL_ADDR_WIDTH-1:0] rot_araddr,rot_awaddr;
    wire rot_arvalid,rot_arready,rot_rvalid,rot_awvalid,rot_wvalid;
    wire [255:0] rot_wdata;
    wire rot_owns_write=rot_busy;
    rotate_bus_ctrl #(.CTRL_ADDR_WIDTH(CTRL_ADDR_WIDTH),.MEM_DQ_WIDTH(32)) bus_ctrl(
        .clk(ddr_clk),.rstn(ddr_rstn),
        .wr_cmd_en(wcmd_en && !rot_owns_write),.wr_cmd_addr(wcmd_addr),
        .wr_cmd_len(wcmd_len),.wr_cmd_ready(wcmd_ready),.wr_cmd_done(wcmd_done),
        .wr_bac(wr_bac),.wr_ctrl_data(capture_data),.wr_data_re(wdata_req),
        .rd_cmd_en(rcmd_en),.rd_cmd_addr(rcmd_addr),.rd_cmd_len(rcmd_len),
        .rd_cmd_ready(rcmd_ready),.rd_cmd_done(rcmd_done),
        .read_ready(1'b1),.read_rdata(scan_data),.read_en(scan_data_en),
        .axi_awaddr(c_awaddr),.axi_awid(),.axi_awlen(c_awlen),
        .axi_awsize(),.axi_awburst(),.axi_awready(axi_awready && !rot_owns_write),
        .axi_awvalid(c_awvalid),.axi_wdata(c_wdata),.axi_wstrb(c_wstrb),
        .axi_wlast(axi_wlast && !rot_owns_write),.axi_wvalid(c_wvalid),
        .axi_wready(axi_wready && !rot_owns_write),.axi_bid(4'd0),
        .axi_bresp(2'd0),.axi_bvalid(1'b0),.axi_bready(),
        .axi_araddr(c_araddr),.axi_arid(),.axi_arlen(c_arlen),
        .axi_arsize(),.axi_arburst(),.axi_arvalid(c_arvalid),.axi_arready(c_arready),
        .axi_rready(),.axi_rdata(axi_rdata),.axi_rvalid(c_rvalid),
        .axi_rlast(axi_rlast && c_rvalid),.axi_rid(axi_rid),.axi_rresp(2'd0));
    rotate_ddr #(.AW(CTRL_ADDR_WIDTH),.WIDTH(RENDER_WIDTH),.HEIGHT(RENDER_HEIGHT),
        .SOURCE_WIDTH(CROP_WIDTH),.SOURCE_HEIGHT(CROP_HEIGHT),
        .FRAME_BITS(FRAME_BITS),.DYNAMIC(1),.RENDER_INTERVAL_CYCLES(RENDER_INTERVAL_CYCLES)) renderer(
        .clk(ddr_clk),.rst_n(ddr_rstn),.cos_q16(angle_cos),.sin_q16(angle_sin),.frame_done(capture_done),
        .source_bank(captured_bank),.vsync(rd_fsync),.capture_enable(capture_enable),
        .display_bank(display_bank),.display_valid(display_valid),.busy(rot_busy),
        .araddr(rot_araddr),.arvalid(rot_arvalid),.arready(rot_arready),
        .rdata(axi_rdata),.rvalid(rot_rvalid),.awaddr(rot_awaddr),
        .awvalid(rot_awvalid),.awready(axi_awready && rot_owns_write),
        .wdata(rot_wdata),.wvalid(rot_wvalid),.wready(axi_wready && rot_owns_write),
        .wlast(axi_wlast && rot_owns_write));
    rotate_read_arb #(.AW(CTRL_ADDR_WIDTH),.PRIORITY_A(1)) read_arb(
        .clk(ddr_clk),.rst_n(ddr_rstn),.a_addr(c_araddr),.a_len(c_arlen),
        .a_valid(c_arvalid),.a_ready(c_arready),.a_rvalid(c_rvalid),
        .b_addr(rot_araddr),.b_valid(rot_arvalid),.b_ready(rot_arready),
        .b_rvalid(rot_rvalid),.araddr(axi_araddr),.arlen(axi_arlen),
        .arvalid(axi_arvalid),.arready(axi_arready),.rvalid(axi_rvalid),.rlast(axi_rlast));
    wire [15:0] scan_pixel;
    wire scan_de;
    rotate_rd_buf #(.ADDR_WIDTH(CTRL_ADDR_WIDTH),.ADDR_OFFSET(32'h01000000),
        .H_NUM(RENDER_WIDTH),.V_NUM(RENDER_HEIGHT),.DQ_WIDTH(32),.LEN_WIDTH(32),.PIX_WIDTH(16),
        .LINE_ADDR_WIDTH(FRAME_BITS),.FRAME_CNT_WIDTH(6),.EXTERNAL_BANK(1)) scanout(
        .ddr_clk(ddr_clk),.ddr_rstn(ddr_rstn),.vout_clk(vout_clk),
        .rd_fsync(rd_fsync),.rd_en(crop_read),.vout_de(scan_de),.vout_data(scan_pixel),
        .init_done(display_valid),.display_bank(display_bank),
        .ddr_rreq(rcmd_en),.ddr_raddr(rcmd_addr),.ddr_rd_len(rcmd_len),
        .ddr_rrdy(rcmd_ready),.ddr_rdone(rcmd_done),
        .ddr_rdata(scan_data),.ddr_rdata_en(scan_data_en));
    assign axi_awaddr=rot_owns_write ? rot_awaddr:c_awaddr;
    assign axi_awlen=rot_owns_write ? 4'd0:c_awlen;
    assign axi_awvalid=rot_owns_write ? rot_awvalid:c_awvalid;
    assign axi_wdata=rot_owns_write ? rot_wdata:c_wdata;
    assign axi_wvalid=rot_owns_write ? rot_wvalid:c_wvalid;
    assign axi_wstrb=32'hffffffff;
    assign axi_awid=0; assign axi_arid=0;
    assign axi_awsize=3'b110; assign axi_arsize=3'b110;
    assign axi_awburst=2'b01; assign axi_arburst=2'b01; assign axi_rready=1;
    reg valid1,valid2;
    reg full_de1,full_de2;
    assign vout_de=full_de2;
    assign vout_data=(scan_de && init_done) ? scan_pixel:16'd0;
    always @(posedge vout_clk or negedge ddr_rstn) begin
        if(!ddr_rstn) begin valid1<=0; valid2<=0; init_done<=0; full_de1<=0; full_de2<=0; end
        else begin valid1<=display_valid; valid2<=valid1; init_done<=valid2;
            full_de1<=rd_en; full_de2<=full_de1; end
    end

endmodule
