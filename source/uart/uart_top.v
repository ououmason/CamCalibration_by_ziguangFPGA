`timescale 1ns/1ps
`default_nettype none

// UART transport plus the minimal binary-frame echo used for bring-up.
module uart_top #(
    parameter integer BPS_NUM = 234
) (
    input  wire clk,
    input  wire rst_n,
    input  wire uart_rx,
    output wire uart_tx,
    output wire [7:0] frame_cmd,
    output wire [7:0] frame_len,
    output wire [2047:0] frame_data,
    output wire frame_valid,
    output wire frame_error
);

    wire [7:0] rx_data;
    wire       rx_valid;
    wire [7:0] tx_data;
    wire       tx_start;
    wire       tx_busy;

    uart_rx #(.BPS_NUM(BPS_NUM)) receiver (
        .clk(clk), .rst_n(rst_n), .uart_rx(uart_rx),
        .rx_data(rx_data), .rx_valid(rx_valid)
    );

    uart_frame_parser parser (
        .clk(clk), .rst_n(rst_n),
        .rx_data(rx_data), .rx_valid(rx_valid),
        .frame_valid(frame_valid), .frame_error(frame_error),
        .frame_cmd(frame_cmd), .frame_len(frame_len), .frame_data(frame_data),
        .tx_busy(tx_busy), .tx_data(tx_data), .tx_start(tx_start)
    );

    uart_tx #(.BPS_NUM(BPS_NUM)) transmitter (
        .clk(clk), .rst_n(rst_n), .tx_data(tx_data),
        .tx_start(tx_start), .uart_tx(uart_tx), .tx_busy(tx_busy)
    );

endmodule

`default_nettype wire
