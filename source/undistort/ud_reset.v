`timescale 1ns/1ps
`default_nettype none

// ============================================================================
// ud_reset : 异步复位 + 同步释放（每个时钟域各自实例化）
// ============================================================================
//
// 每个时钟域（clk / pclk / oclk）各自实例化一个 ud_reset，保证复位的
// 释放与本地时钟同步，避免跨时钟域的复位毛刺。
//
// arst_n 低有效异步置位；释放后通过三级同步链（sync[0..2]）同步到 clk 域，
// 输出 rst_n = sync[2] 高有效（去复位后为 1）。sync 寄存器用 async_reg 属性
// 标记，便于综合器正确推断异步复位同步链。
// ============================================================================
module ud_reset (
    input  wire clk,
    input  wire arst_n,
    output wire rst_n
);

    (* async_reg = "true" *) reg [2:0] sync;

    always @(posedge clk or negedge arst_n) begin
        if (!arst_n)
            sync <= 0;              // 异步复位
        else
            sync <= {sync[1:0], 1'b1};  // 同步释放：逐拍灌 1
    end

    assign rst_n = sync[2];

endmodule

// ============================================================================
// ud_key_toggle : 按键消抖 + 单次触发翻转（矫正模式开关）
// ============================================================================
// 每次有效按下只翻转一次 enabled；释放后重新武装下一次按压。默认 27 MHz
// 板上时钟，20 ms 稳定电平（DEBOUNCE_CYCLES = 540000）分别用于按下与释放。
// key 极性由 KEY_ACTIVE_LOW 决定（默认低有效）。LED 由 LED_ACTIVE_LOW 决定极性。
// ============================================================================
module ud_key_toggle #(
    parameter DEBOUNCE_CYCLES = 540000,
    parameter KEY_ACTIVE_LOW  = 1,
    parameter LED_ACTIVE_LOW  = 0
) (
    input  wire clk,
    input  wire rst_n,
    input  wire key,
    output reg  enabled,
    output wire led
);

    function integer counter_bits;
        input integer depth;
        integer n;
        begin
            counter_bits = 0;
            for (n = depth - 1; n > 0; n = n >> 1)
                counter_bits = counter_bits + 1;
            if (counter_bits == 0)
                counter_bits = 1;
        end
    endfunction

    localparam CBITS = counter_bits(DEBOUNCE_CYCLES);

    (* async_reg = "true" *) reg [1:0] key_sync;   // 按键异步同步链
    reg pressed;                                    // 当前稳定后的按键状态
    reg [CBITS-1:0] stable_count;                    // 稳定期计数

    assign led = LED_ACTIVE_LOW ? ~enabled : enabled;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            key_sync <= 0;
            pressed <= 0;
            stable_count <= 0;
            enabled <= 0;
        end else begin
            // 采样并（可选）取反以匹配极性
            key_sync <= {key_sync[0], KEY_ACTIVE_LOW ? ~key : key};
            // 若按键电平与当前稳定状态不一致，则重新计数（等待稳定）
            if (key_sync[1] == pressed)
                stable_count <= 0;
            else if (stable_count == DEBOUNCE_CYCLES - 1) begin
                // 电平已稳定满 20ms：更新状态，并在按下沿翻转 enabled
                pressed <= key_sync[1];
                stable_count <= 0;
                if (key_sync[1])
                    enabled <= ~enabled;
            end else
                stable_count <= stable_count + 1'b1;
        end
    end

endmodule

`default_nettype wire