`timescale 1ns/1ps
`default_nettype none

module uart_rx #(
    parameter integer BPS_NUM = 234
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       uart_rx,
    output reg  [7:0] rx_data,
    output reg        rx_valid
);

    localparam [1:0] RX_IDLE  = 2'd0;
    localparam [1:0] RX_START = 2'd1;
    localparam [1:0] RX_DATA  = 2'd2;
    localparam [1:0] RX_STOP  = 2'd3;
    localparam integer HALF_BIT = BPS_NUM / 2;

    (* async_reg = "true" *) reg [1:0] rx_sync;
    reg        rx_sync_d;
    reg [1:0]  state;
    reg [15:0] baud_count;
    reg [2:0]  bit_index;
    reg [7:0]  data_shift;

    wire rx_falling = rx_sync_d && !rx_sync[1];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_sync   <= 2'b11;
            rx_sync_d <= 1'b1;
        end else begin
            rx_sync   <= {rx_sync[0], uart_rx};
            rx_sync_d <= rx_sync[1];
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= RX_IDLE;
            baud_count <= 16'd0;
            bit_index  <= 3'd0;
            data_shift <= 8'd0;
            rx_data    <= 8'd0;
            rx_valid   <= 1'b0;
        end else begin
            rx_valid <= 1'b0;

            case (state)
                RX_IDLE: begin
                    baud_count <= 16'd0;
                    bit_index  <= 3'd0;
                    if (rx_falling)
                        state <= RX_START;
                end

                RX_START: begin
                    if (baud_count == HALF_BIT - 1) begin
                        baud_count <= 16'd0;
                        if (!rx_sync[1])
                            state <= RX_DATA;
                        else
                            state <= RX_IDLE;
                    end else begin
                        baud_count <= baud_count + 1'b1;
                    end
                end

                RX_DATA: begin
                    if (baud_count == BPS_NUM - 1) begin
                        baud_count           <= 16'd0;
                        data_shift[bit_index] <= rx_sync[1];
                        if (bit_index == 3'd7) begin
                            bit_index <= 3'd0;
                            state     <= RX_STOP;
                        end else begin
                            bit_index <= bit_index + 1'b1;
                        end
                    end else begin
                        baud_count <= baud_count + 1'b1;
                    end
                end

                RX_STOP: begin
                    if (baud_count == BPS_NUM - 1) begin
                        baud_count <= 16'd0;
                        state      <= RX_IDLE;
                        if (rx_sync[1]) begin
                            rx_data  <= data_shift;
                            rx_valid <= 1'b1;
                        end
                    end else begin
                        baud_count <= baud_count + 1'b1;
                    end
                end

                default: state <= RX_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
