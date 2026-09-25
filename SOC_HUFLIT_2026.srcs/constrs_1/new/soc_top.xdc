create_clock -period 20.000 -name sys_clk [get_ports clk]

#create_generated_clock -name ddr_clk_out \
#    -source [get_pins u_parallel_axi/u_ddr_result_serializer/u_oddr_clk/C] \
#    -divide_by 1 \
#    -invert \
#    [get_ports ddr_clk_out]
    
set DDR_TSU            2.000 ; 
set DDR_THD            1.000 ; 
set DDR_BOARD_SKEW_MAX 0.500 ; 
set DDR_BOARD_SKEW_MIN 0.100 ; 

set OUT_DELAY_MAX [expr {$DDR_TSU + $DDR_BOARD_SKEW_MAX}]
set OUT_DELAY_MIN [expr {-$DDR_THD - $DDR_BOARD_SKEW_MIN}]

set DDR_PORTS [get_ports {ddr_data[*] ddr_valid ddr_done}]

set DDR_DATA_PORTS  [get_ports {ddr_data[*]}]
set DDR_FLAG_PORTS  [get_ports {ddr_valid ddr_done}]

set_output_delay -clock ddr_clk_out -max $OUT_DELAY_MAX $DDR_DATA_PORTS
set_output_delay -clock ddr_clk_out -min $OUT_DELAY_MIN $DDR_DATA_PORTS
set_output_delay -clock ddr_clk_out -max $OUT_DELAY_MAX $DDR_DATA_PORTS -clock_fall -add_delay
set_output_delay -clock ddr_clk_out -min $OUT_DELAY_MIN $DDR_DATA_PORTS -clock_fall -add_delay

set_output_delay -clock ddr_clk_out -max $OUT_DELAY_MAX $DDR_FLAG_PORTS
set_output_delay -clock ddr_clk_out -min $OUT_DELAY_MIN $DDR_FLAG_PORTS

