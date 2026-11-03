`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2022/03/16 23:40:57
// Design Name: 
// Module Name: udp_ip_mac_top
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


module udp_ip_mac_top #(
    parameter       LOCAL_MAC = 48'h11_11_11_11_11_11,
    parameter       LOCAL_IP  = 32'hC0_A8_01_0B,
    parameter       LOCL_PORT = 16'h8080,
    parameter       DEST_MAC  = 48'h04_D9_F5_89_43_66,
    parameter       DEST_IP   = 32'hC0_A8_01_69,
    parameter       DEST_PORT = 16'h04D2 
)(
    input           rgmii_clk,
    input           rstn,
    
    input           app_data_in_valid,
    input   [7:0]   app_data_in,      
    input   [15:0]  app_data_length,    
    input           app_data_request, 
                                      
    output          udp_send_ack,   
    
    input           arp_req,
    output          arp_found,
    output          mac_not_exist,
    output          mac_send_end,

    output  [7:0]   udp_rec_rdata ,      //udp ram read data   
    output  [15:0]  udp_rec_data_length,     //udp data length     
    output          udp_rec_data_valid,       //udp data valid      
    
    output          mac_data_valid,
    output  [7:0]   mac_tx_data,   
                                   
    input           rx_en,         
    input   [7:0]   mac_rx_datain
);
    
    wire             udp_tx_req;         
    wire             udp_tx_ready;       
    wire     [7:0]   udp_tx_data;         
    wire     [15:0]  udp_send_data_length;
    wire             udp_tx_ack;         
                     
    wire             upper_data_req;  
    wire             udp_rx_req; 
    wire             ip_addr_check_error;
    wire [7:0]       net_protocol;      
    wire [31:0]      ip_rec_source_addr;
    wire [31:0]      ip_rec_dest_addr; 
    wire             ip_checksum_error;
    wire [15:0]      upper_layer_data_length;
 
    wire             mac_data_req;
    wire             mac_rec_err;
    wire  [7:0]      mac_rx_dataout;   

    udp_layer #(
        .LOCAL_PORT_NUM          (  LOCL_PORT                ) //parameter LOCAL_PORT_NUM = 16'hf000    //Դ�˿ں�
    )udp_layer (                                             
        .udp_send_clk            (  rgmii_clk                ),//input              udp_send_clk,               //ʱ���ź�                                                                                                                                                                                                                                                                                                                                                                
        .rstn                    (  rstn                     ),//input              rstn,                       //��λ�źţ��͵�ƽ��Ч                                                                                                                                                                                                                                                                                                                                                    
                                                                                                                                                                                                                                                                                                                                                                                                                            
        //from software app                                                                                                                                                                                                                                                                                                                                                                                                   
        .app_data_in_valid       (  app_data_in_valid        ),//input              app_data_in_valid,          //��ģ����ⲿ�����յ����������Ч�źţ��ߵ�ƽ��Ч                                                                                                                                                                                                                                                                                                                        
        .app_data_in             (  app_data_in              ),//input      [7:0]   app_data_in,                //��ģ����ⲿ�����յ��������                                                                                                                                                                                                                                                                                                                                            
        .app_data_length         (  app_data_length          ),//input      [15:0]  app_data_length,            //��ģ����ⲿ�����յĵ�ǰ���ݰ��ĳ��ȣ�����udp��ip��mac �ײ�������λ���ֽ�                                                                                                                                                                                                                                                                                               
        .udp_dest_port           (  DEST_PORT                ),//input      [15:0]  udp_dest_port,              //��ģ����ⲿ�����յ����ݰ���Դ�˿ں�                                                                                                                                                                                                                                                                                                                                    
        .app_data_request        (  app_data_request         ),//input              app_data_request,           //�û��ӿ����ݷ������󣬸ߵ�ƽ��Ч                                                                                                                                                                                                                                                                                                                                        
                                                                                                                                                                                                                                                                                                                                                                                                                             
        .udp_send_ack            (  udp_send_ack             ),//output             udp_send_ack,               //�����ǻ��� ready��request��ack�����ź���ʵ�ֵ�                                                                                                                                                                                                                                                                                                                          
                                                                                                                                                                                                                                                                                                                                                                                                   
        .udp_send_ready          (  udp_tx_ready             ),//output          udp_send_ready,             //�����ǻ��� ready��request��ack�����ź���ʵ�ֵ�                                                                                                                                                                                                                                                                                                                                                                                    
        .ip_send_ready           (  upper_data_req           ),//input           ip_send_ready,              //�����ǻ��� ready��request��ack�����ź���ʵ�ֵ�                                                                                                                                                                                                                                                                                                                          
        .ip_send_ack             (  udp_tx_ack               ),//input           ip_send_ack,                //�����ǻ��� ready��request��ack�����ź���ʵ�ֵ�                                                                                                                                                                                                                                                                                                                          
        //to IP_send                                                                                                                                                                                                                                                                                                                                                                                                          
        .udp_send_request        (  udp_tx_req               ),//output          udp_send_request,           //�û��ӿ����ݷ������󣬸ߵ�ƽ��Ч                                                                                                                                                                                                                                                                                                                                        
        .udp_data_out_valid      (                           ),//output          udp_data_out_valid,         //���͵����������Ч�źţ��ߵ�ƽ��Ч                                                                                                                                                                                                                                                                                                                                      
        .udp_data_out            (  udp_tx_data              ),//output  [7:0]   udp_data_out,               //���͵��������                                                                                                                                                                                                                                                                                                                                                          
        .udp_packet_length       (  udp_send_data_length     ),//output  [15:0]  udp_packet_length,          //��ǰ���ݰ��ĳ��ȣ�����udp��ip��mac �ײ�������λ���ֽ�  
                                                             
        .udp_rx_data             (  mac_rx_dataout           ),//input      [7:0]   udp_rx_data,
        .udp_rx_req              (  udp_rx_req               ),//input              udp_rx_req,
                                                             
        .ip_checksum_error       (  ip_checksum_error        ),//input              ip_checksum_error,
        .ip_addr_check_error     (  ip_addr_check_error      ),//input              ip_addr_check_error,
        
        .udp_rec_rdata           (  udp_rec_rdata            ),//output     [7:0]   udp_rec_rdata ,      //udp ram read data
        .udp_rec_data_length     (  udp_rec_data_length      ),//output     [15:0]  udp_rec_data_length,     //udp data length
        .udp_rec_data_valid      (  udp_rec_data_valid       ) //output             udp_rec_data_valid       //udp data valid
    );

    wire          ip_tx_ready;
    wire [7:0]    ip_tx_data ;
    wire          ip_tx_end  ;
    wire          ip_tx_ack  ; 
    wire          mac_tx_req;
    wire          ip_rx_end  ;
    wire          ip_rx_req  ;       
    wire  [47:0]  mac_rx_dest_mac_addr;
    wire  [47:0]  mac_rx_sour_mac_addr;
    wire  [47:0]  arp_dest_mac_addr;

    ip_layer#(
        .LOCAL_IP                (  LOCAL_IP                 ),//parameter    LOCAL_IP  = 32'hC0_A8_00_02,
        .LOCAL_MAC               (  LOCAL_MAC                ) //parameter    LOCAL_MAC = 48'h3C_2B_1A_09_4D_5E
    ) ip_layer (                                              
        .clk                     (  rgmii_clk                ),//input              clk, 
        .rstn                    (  rstn                     ),//input              rstn,
        //MAC TX                                             
        .mac_tx_ack              (  ip_tx_ack                ),//input              mac_tx_ack,  
        .mac_send_end            (  mac_send_end             ),//input              mac_send_end,
        .mac_data_req            (  mac_data_req             ),//input              mac_data_req,
        .ip_tx_req               (  ip_tx_req               ),//output             mac_tx_req,                                                     
        .ip_tx_ready             (  ip_tx_ready              ),//output             ip_tx_ready, 
        .ip_tx_data              (  ip_tx_data               ),//output [7:0]       ip_tx_data,  
        .ip_tx_end               (  ip_tx_end                ),//output             ip_tx_end,    
        //MAC RX                                             
        .ip_rx_data              (  mac_rx_dataout           ),//input  [7:0]       ip_rx_data,          
        .ip_rx_req               (  ip_rx_req                ),//input              ip_rx_req,           
        .mac_rx_dest_mac_addr    (  mac_rx_dest_mac_addr     ),//input  [47:0]      mac_rx_dest_mac_addr,
        .ip_rx_end               (  ip_rx_end                ),//output             ip_rx_end,  
                                                             
        .mac_rec_err             (  mac_rec_err              ),//input              mac_rec_err,  
        //UPPER LAYER TX                                     
        .dest_mac_addr           (  arp_dest_mac_addr        ),//input  [47:0]      dest_mac_addr,
        .dest_ip_addr            (  DEST_IP                  ),//input  [31:0]      dest_ip_addr,
                                                             
        .udp_tx_req              (  udp_tx_req               ),//input              udp_tx_req,          
        .udp_tx_ready            (  udp_tx_ready             ),//input              udp_tx_ready ,       
        .udp_tx_data             (  udp_tx_data              ),//input      [7:0]   udp_tx_data,         
        .udp_send_data_length    (  udp_send_data_length     ),//input      [15:0]  udp_send_data_length,
        .udp_tx_ack              (  udp_tx_ack               ),//output             udp_tx_ack,     
                                                             
        .upper_data_req          (  upper_data_req           ),//output             upper_data_req,    
                                                     
        //UPPER LAYER RX                                     
        .udp_rx_req              (  udp_rx_req               ),//output             udp_rx_req,
        .ip_addr_check_error     (  ip_addr_check_error      ),//output             ip_addr_check_error,                                                       
        .net_protocol            (  net_protocol             ),//output [7:0]       net_protocol,           
        .ip_rec_source_addr      (  ip_rec_source_addr       ),//output [31:0]      ip_rec_source_addr,     
        .ip_rec_dest_addr        (  ip_rec_dest_addr         ),//output [31:0]      ip_rec_dest_addr,   
        .upper_layer_data_length (  upper_layer_data_length  ),//output [15:0]      upper_layer_data_length,      
        .ip_checksum_error       (  ip_checksum_error        ) //output             ip_checksum_error       
    );                                                       
                                                             
    arp_mac_top#(                                            
        .LOCAL_MAC_ADDR          (  LOCAL_MAC                ),//parameter LOCAL_MAC_ADDR = 48'h3C_2B_1A_09_4D_5E,
        .LOCAL_IP_ADDR           (  LOCAL_IP                 ) //parameter LOCAL_IP_ADDR  = 24'hC0_A8_00_02,
    ) arp_mac_top_U1 (                                       
        .clk                     (  rgmii_clk                ),//input           clk,
        .rstn                    (  rstn                     ),//input           rstn,
                                                             
        .checksum_err            (  ip_checksum_error        ),//input           checksum_err,
                                                             
        .ip_tx_req               (  ip_tx_req                ),//input           ip_tx_req     ,
        .ip_tx_ready             (  ip_tx_ready              ),//input           ip_tx_ready   ,
        .ip_tx_data              (  ip_tx_data               ),//input  [7:0]    ip_tx_data    ,
        .ip_tx_end               (  ip_tx_end                ),//input           ip_tx_end     ,
        .ip_tx_ack               (  ip_tx_ack                ),//output          ip_tx_ack     ,
        .mac_data_req            (  mac_data_req             ),//output          mac_data_req  ,
        .mac_send_end            (  mac_send_end             ),//output          mac_send_end  ,
                                                                                            
        .ip_rx_end               (  ip_rx_end                ),//input           ip_rx_end     ,
        .ip_rx_req               (  ip_rx_req                ),//output          ip_rx_req     ,
        .mac_rx_dataout          (  mac_rx_dataout           ),//output  [7:0]   mac_rx_dataout,                      
        .mac_rx_dest_mac_addr    (  mac_rx_dest_mac_addr     ),//output  [47:0]  mac_rx_dest_mac_addr,                
        .mac_rx_sour_mac_addr    (  mac_rx_sour_mac_addr     ),//output  [47:0]  mac_rx_sour_mac_addr,                
                                                             
        .arp_request_req         (  arp_req                  ),//input           arp_request_req, 
        .arp_found               (  arp_found                ),//output          arp_found,
        .mac_not_exist           (  mac_not_exist            ),//output          mac_not_exist,
        .arp_dest_mac_addr       (  arp_dest_mac_addr        ),//output [47:0]   arp_dest_mac_addr,
        
        .dest_ip_addr            (  DEST_IP                  ),//input           dest_ip_addr,
                                                             
        .mac_rec_error           (  mac_rec_err              ),//output          mac_rec_error
                                                             
        .mac_data_valid          (  mac_data_valid           ),//output          mac_data_valid, 
        .mac_tx_data             (  mac_tx_data              ),//output  [7:0]   mac_tx_data,           
                                                                                                         
        .rx_en                   (  rx_en                    ),//input           rx_en,                  
        .mac_rx_datain           (  mac_rx_datain            ) //input   [7:0]   mac_rx_datain,          
    );
endmodule
