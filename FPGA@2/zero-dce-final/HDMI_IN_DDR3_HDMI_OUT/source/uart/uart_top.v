`timescale 1ns/1ps
`default_nettype none

// UART 8N1 receiver: Y=-3.40\r\n -> angle_y_cdeg=-340.
// BPS_NUM: clocks per bit (234 at 27 MHz / 115200 baud).
module uart_top #(
    parameter integer BPS_NUM = 234,
    parameter integer RX_TIMEOUT_CYCLES = 2_700_000
) (
    input wire clk,
    input wire rst_n,
    input wire uart_rx,
    output wire uart_tx,
    output wire signed [31:0] angle_y_cdeg,
    output wire angle_valid,
    output wire angle_error
);
    wire [7:0] rx_data;
    wire rx_valid;

    uart_rx #(.BPS_NUM(BPS_NUM)) receiver (
        .clk(clk), .rst_n(rst_n), .uart_rx(uart_rx),
        .rx_data(rx_data), .rx_valid(rx_valid)
    );
    uart_frame_parser #(.RX_TIMEOUT_CYCLES(RX_TIMEOUT_CYCLES)) parser (
        .clk(clk), .rst_n(rst_n),
        .rx_data(rx_data), .rx_valid(rx_valid),
        .angle_y_cdeg(angle_y_cdeg),
        .angle_valid(angle_valid), .angle_error(angle_error)
    );
    // No reply required; keep transmit at UART idle level.
    assign uart_tx = 1'b1;
endmodule

`default_nettype wire
