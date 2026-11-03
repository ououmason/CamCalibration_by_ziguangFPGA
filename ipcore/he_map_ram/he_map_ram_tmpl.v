// Created by IP Generator (Version 2023.2-SP4 build 166183)
// Instantiation Template
//
// Insert the following codes into your Verilog file.
//   * Change the_instance_name to your own instance name.
//   * Change the signal names in the port associations


he_map_ram the_instance_name (
  .wr_data(wr_data),    // input [7:0]
  .wr_addr(wr_addr),    // input [8:0]
  .rd_addr(rd_addr),    // input [8:0]
  .wr_clk(wr_clk),      // input
  .rd_clk(rd_clk),      // input
  .wr_en(wr_en),        // input
  .rst(rst),            // input
  .rd_data(rd_data)     // output [7:0]
);
