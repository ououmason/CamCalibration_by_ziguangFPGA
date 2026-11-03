`timescale 1ns/1ps
`default_nettype none

// Minimal binary frame parser and test echo.
// Frame format: 55 CMD LEN DATA[LEN] CHECK AA.
// CHECK is the low byte of CMD + LEN + DATA.
module uart_frame_parser #(
    parameter integer DATA_BYTES = 256,
    parameter integer RX_TIMEOUT_CYCLES = 2_700_000
) (
    input  wire                   clk,
    input  wire                   rst_n,
    input  wire [7:0]             rx_data,
    input  wire                   rx_valid,
    output reg                    frame_valid,
    output reg                    frame_error,
    output reg  [7:0]             frame_cmd,
    output reg  [7:0]             frame_len,
    output reg  [DATA_BYTES*8-1:0] frame_data,
    input  wire                   tx_busy,
    output reg  [7:0]             tx_data,
    output reg                    tx_start
);

    localparam [2:0] S_IDLE  = 3'd0;
    localparam [2:0] S_CMD   = 3'd1;
    localparam [2:0] S_LEN   = 3'd2;
    localparam [2:0] S_DATA  = 3'd3;
    localparam [2:0] S_CHECK = 3'd4;
    localparam [2:0] S_TAIL  = 3'd5;

    localparam [1:0] T_IDLE  = 2'd0;
    localparam [1:0] T_START = 2'd1;
    localparam [1:0] T_BUSY  = 2'd2;
    localparam [1:0] T_DONE  = 2'd3;

    reg [2:0] state;
    reg [7:0] checksum;
    reg [7:0] data_index;
    reg [7:0] data_buf [0:DATA_BYTES-1];
    reg [21:0] timeout_count;

    reg [1:0] tx_state;
    reg [8:0] tx_index;
    reg       echo_pending;
    reg       echo_request;
    reg [7:0] echo_cmd;
    reg [7:0] echo_len;
    reg [7:0] echo_checksum;

    integer i;

    // The test response is an exact echo of a valid frame. It is deliberately
    // kept in this module so the first hardware test has no application logic.
    always @(*) begin
        tx_data = 8'h00;
        case (tx_index)
            9'd0: tx_data = 8'h55;
            9'd1: tx_data = echo_cmd;
            9'd2: tx_data = echo_len;
            default: begin
                if (tx_index >= 9'd3 && tx_index < (9'd3 + echo_len))
                    tx_data = data_buf[tx_index - 9'd3];
                else if (tx_index == (9'd3 + echo_len))
                    tx_data = echo_checksum;
                else if (tx_index == (9'd4 + echo_len))
                    tx_data = 8'hAA;
            end
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= S_IDLE;
            checksum      <= 8'h00;
            data_index    <= 8'h00;
            timeout_count <= 22'd0;
            frame_valid   <= 1'b0;
            frame_error   <= 1'b0;
            frame_cmd     <= 8'h00;
            frame_len     <= 8'h00;
            frame_data    <= {(DATA_BYTES*8){1'b0}};
            echo_request  <= 1'b0;
            echo_cmd      <= 8'h00;
            echo_len      <= 8'h00;
            echo_checksum <= 8'h00;
        end else begin
            frame_valid <= 1'b0;
            frame_error <= 1'b0;
            echo_request <= 1'b0;

            if (state == S_IDLE) begin
                timeout_count <= 22'd0;
            end else if (rx_valid) begin
                timeout_count <= 22'd0;
            end else if (timeout_count == RX_TIMEOUT_CYCLES - 1) begin
                state         <= S_IDLE;
                timeout_count <= 22'd0;
                frame_error   <= 1'b1;
            end else begin
                timeout_count <= timeout_count + 1'b1;
            end

            if (rx_valid) begin
                case (state)
                    S_IDLE: begin
                        if (rx_data == 8'h55) begin
                            checksum   <= 8'h00;
                            data_index <= 8'h00;
                            state      <= S_CMD;
                        end
                    end

                    S_CMD: begin
                        frame_cmd <= rx_data;
                        checksum  <= rx_data;
                        state     <= S_LEN;
                    end

                    S_LEN: begin
                        frame_len <= rx_data;
                        checksum  <= checksum + rx_data;
                        data_index <= 8'h00;
                        if (rx_data == 8'h00)
                            state <= S_CHECK;
                        else
                            state <= S_DATA;
                    end

                    S_DATA: begin
                        data_buf[data_index] <= rx_data;
                        checksum <= checksum + rx_data;
                        if (data_index == frame_len - 1'b1) begin
                            state <= S_CHECK;
                        end else begin
                            data_index <= data_index + 1'b1;
                        end
                    end

                    S_CHECK: begin
                        if (rx_data == checksum)
                            state <= S_TAIL;
                        else begin
                            state       <= S_IDLE;
                            frame_error <= 1'b1;
                        end
                    end

                    S_TAIL: begin
                        if (rx_data == 8'hAA) begin
                            frame_valid  <= 1'b1;
                            echo_request <= 1'b1;
                            echo_cmd     <= frame_cmd;
                            echo_len     <= frame_len;
                            echo_checksum <= checksum;
                            for (i = 0; i < DATA_BYTES; i = i + 1)
                                frame_data[i*8 +: 8] <= data_buf[i];
                        end else begin
                            frame_error <= 1'b1;
                        end
                        state <= S_IDLE;
                    end

                    default: state <= S_IDLE;
                endcase
            end
        end
    end

    // Send one complete echo frame at a time. Host sends the next test frame
    // after receiving this response, so no application-level queue is needed.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_state     <= T_IDLE;
            tx_index     <= 9'd0;
            echo_pending <= 1'b0;
            tx_start     <= 1'b0;
        end else begin
            tx_start <= 1'b0;
            if (echo_request)
                echo_pending <= 1'b1;
            case (tx_state)
                T_IDLE: begin
                    if (echo_pending && !tx_busy) begin
                        echo_pending <= 1'b0;
                        tx_index     <= 9'd0;
                        tx_start     <= 1'b1;
                        tx_state     <= T_START;
                    end
                end

                T_START: begin
                    if (tx_busy)
                        tx_state <= T_BUSY;
                end

                T_BUSY: begin
                    if (!tx_busy)
                        tx_state <= T_DONE;
                end

                T_DONE: begin
                    if (tx_index == (9'd4 + echo_len)) begin
                        tx_state <= T_IDLE;
                    end else if (!tx_busy) begin
                        tx_index <= tx_index + 1'b1;
                        tx_start <= 1'b1;
                        tx_state <= T_START;
                    end
                end

                default: tx_state <= T_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
