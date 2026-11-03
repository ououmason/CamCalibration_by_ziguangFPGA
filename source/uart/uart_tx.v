`timescale 1ns/1ps
`default_nettype none

module uart_tx #(
    parameter integer BPS_NUM = 234
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] tx_data,
    input  wire       tx_start,
    output reg        uart_tx,
    output wire       tx_busy
);

    localparam [1:0] TX_IDLE  = 2'd0;
    localparam [1:0] TX_START = 2'd1;
    localparam [1:0] TX_DATA  = 2'd2;
    localparam [1:0] TX_STOP  = 2'd3;

    reg [1:0]  state;
    reg [15:0] baud_count;
    reg [2:0]  bit_index;
    reg [7:0]  data_latched;

    assign tx_busy = (state != TX_IDLE);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= TX_IDLE;
            baud_count   <= 16'd0;
            bit_index    <= 3'd0;
            data_latched <= 8'd0;
            uart_tx      <= 1'b1;
        end else begin
            case (state)
                TX_IDLE: begin
                    baud_count <= 16'd0;
                    bit_index  <= 3'd0;
                    uart_tx    <= 1'b1;
                    if (tx_start) begin
                        data_latched <= tx_data;
                        uart_tx      <= 1'b0;
                        state        <= TX_START;
                    end
                end

                TX_START: begin
                    if (baud_count == BPS_NUM - 1) begin
                        baud_count <= 16'd0;
                        uart_tx    <= data_latched[0];
                        state      <= TX_DATA;
                    end else begin
                        baud_count <= baud_count + 1'b1;
                    end
                end

                TX_DATA: begin
                    if (baud_count == BPS_NUM - 1) begin
                        baud_count <= 16'd0;
                        if (bit_index == 3'd7) begin
                            bit_index <= 3'd0;
                            uart_tx   <= 1'b1;
                            state     <= TX_STOP;
                        end else begin
                            bit_index <= bit_index + 1'b1;
                            uart_tx   <= data_latched[bit_index + 1'b1];
                        end
                    end else begin
                        baud_count <= baud_count + 1'b1;
                    end
                end

                TX_STOP: begin
                    if (baud_count == BPS_NUM - 1) begin
                        baud_count <= 16'd0;
                        uart_tx    <= 1'b1;
                        state      <= TX_IDLE;
                    end else begin
                        baud_count <= baud_count + 1'b1;
                    end
                end

                default: begin
                    state   <= TX_IDLE;
                    uart_tx <= 1'b1;
                end
            endcase
        end
    end

endmodule

`default_nettype wire
