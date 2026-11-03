`timescale 1ns/1ps
`default_nettype none

// ASCII Y=[+|-]digits.dd\r\n. Signed result in 0.01 degree units.
// Update on LF only, and retain the last good angle on errors/idle.
module uart_frame_parser #(
    parameter integer RX_TIMEOUT_CYCLES = 2_700_000
) (
    input wire clk,
    input wire rst_n,
    input wire [7:0] rx_data,
    input wire rx_valid,
    output reg signed [31:0] angle_y_cdeg,
    output reg angle_valid,
    output reg angle_error
);
    localparam [3:0] S_IDLE=0, S_EQUAL=1, S_FIRST=2, S_INT=3,
                     S_FRAC1=4, S_FRAC2=5, S_CR=6, S_LF=7;
    localparam integer TIMEOUT_WIDTH =
        (RX_TIMEOUT_CYCLES > 1) ? $clog2(RX_TIMEOUT_CYCLES) : 1;
    reg [3:0] state;
    reg negative;
    reg integer_seen;
    reg [31:0] magnitude;
    reg [TIMEOUT_WIDTH-1:0] timeout_count;
    wire is_digit = (rx_data >= 8'h30) && (rx_data <= 8'h39);
    // Widen before multiplication to detect overflow without wrapping.
    wire [35:0] next_magnitude =
        {4'd0, magnitude} * 36'd10 + {32'd0, rx_data[3:0]};
    wire [35:0] magnitude_limit =
        negative ? 36'd2147483648 : 36'd2147483647;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            negative <= 1'b0;
            integer_seen <= 1'b0;
            magnitude <= 32'd0;
            timeout_count <= {TIMEOUT_WIDTH{1'b0}};
            angle_y_cdeg <= 32'sd0;
            angle_valid <= 1'b0;
            angle_error <= 1'b0;
        end else begin
            angle_valid <= 1'b0;
            angle_error <= 1'b0;
            if ((state == S_IDLE) || rx_valid)
                timeout_count <= {TIMEOUT_WIDTH{1'b0}};
            else if (timeout_count == RX_TIMEOUT_CYCLES - 1) begin
                state <= S_IDLE;
                timeout_count <= {TIMEOUT_WIDTH{1'b0}};
                angle_error <= 1'b1;
            end else
                timeout_count <= timeout_count + 1'b1;

            if (rx_valid) begin
                // A new Y immediately starts a new line, including after truncation.
                if (rx_data == 8'h59) begin
                    state <= S_EQUAL;
                    negative <= 1'b0;
                    integer_seen <= 1'b0;
                    magnitude <= 32'd0;
                    if (state != S_IDLE) angle_error <= 1'b1;
                end else begin
                    case (state)
                        S_IDLE: begin end
                        S_EQUAL: begin
                            if (rx_data == 8'h3D) state <= S_FIRST;
                            else begin state <= S_IDLE; angle_error <= 1'b1; end
                        end
                        S_FIRST: begin
                            if ((rx_data == 8'h2D) || (rx_data == 8'h2B)) begin
                                negative <= (rx_data == 8'h2D);
                                state <= S_INT;
                            end else if (is_digit) begin
                                magnitude <= {28'd0, rx_data[3:0]};
                                integer_seen <= 1'b1;
                                state <= S_INT;
                            end else begin state <= S_IDLE; angle_error <= 1'b1; end
                        end
                        S_INT, S_FRAC1, S_FRAC2: begin
                            if (is_digit && (next_magnitude <= magnitude_limit)) begin
                                magnitude <= next_magnitude[31:0];
                                if (state == S_INT) integer_seen <= 1'b1;
                                else if (state == S_FRAC1) state <= S_FRAC2;
                                else state <= S_CR;
                            end else if ((state == S_INT) && integer_seen &&
                                         (rx_data == 8'h2E)) state <= S_FRAC1;
                            else begin state <= S_IDLE; angle_error <= 1'b1; end
                        end
                        S_CR: begin
                            if (rx_data == 8'h0D) state <= S_LF;
                            else begin state <= S_IDLE; angle_error <= 1'b1; end
                        end
                        S_LF: begin
                            if (rx_data == 8'h0A) begin
                                angle_y_cdeg <= negative ?
                                    -$signed(magnitude) : $signed(magnitude);
                                angle_valid <= 1'b1;
                            end else angle_error <= 1'b1;
                            state <= S_IDLE;
                        end
                        default: state <= S_IDLE;
                    endcase
                end
            end
        end
    end
endmodule

`default_nettype wire
