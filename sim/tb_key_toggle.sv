`timescale 1ns/1ps
module tb_key_toggle;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,key=1;
    wire enabled,led,inverted_enabled,inverted_led;
    ud_key_toggle #(.DEBOUNCE_CYCLES(8)) dut(clk,rst_n,key,enabled,led);
    ud_key_toggle #(.DEBOUNCE_CYCLES(8),.KEY_ACTIVE_LOW(0),.LED_ACTIVE_LOW(1))
        inverted(clk,rst_n,~key,inverted_enabled,inverted_led);
    task clocks(input integer n); repeat(n) @(negedge clk); endtask
    task check(input bit expected);
        if(enabled!==expected || led!==expected || inverted_enabled!==expected || inverted_led!==!expected)
            $fatal(1,"toggle/LED state expected=%b got=%b led=%b",expected,enabled,led);
    endtask
    initial begin
        clocks(3);check(0);rst_n=1;clocks(12);check(0);
        key=0;clocks(3);key=1;clocks(3);key=0;clocks(2);key=1;clocks(12);check(0);
        key=0;clocks(12);check(1);clocks(200);check(1);
        key=1;clocks(3);key=0;clocks(12);check(1);
        key=1;clocks(12);check(1);
        key=0;clocks(12);check(0);clocks(50);check(0);
        key=1;clocks(12);key=0;clocks(12);check(1);
        rst_n=0;clocks(3);check(0);key=1;rst_n=1;clocks(12);check(0);
        $display("PASS key: debounce, single-click toggle, long hold, release, reset, both polarities");
        $finish;
    end
endmodule
