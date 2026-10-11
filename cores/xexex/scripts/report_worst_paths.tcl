# Worst setup paths into one clock, from the compiled database, no recompile.
# From the target's build folder (<repo>-build/mister/cores/xexex/mister):
#   quartus_sta -t report_worst_paths.tcl jtxexex [pll-output]
# pll-output is the emu PLL's general[] index: 4 is the 96 MHz clock under
# JTFRAME_SDRAM96, 0 the 48 MHz one. Adapted from the mister-arcade-core skill.
set rev [lindex $quartus(args) 0]
set n 4
if {[llength $quartus(args)] > 1} { set n [lindex $quartus(args) 1] }
project_open $rev
create_timing_netlist
read_sdc
update_timing_netlist
set clk "emu|pll|pll_inst|altera_pll_i|general\[$n\].gpll~PLL_OUTPUT_COUNTER|divclk"
report_timing -setup -npaths 20 -detail summary -to_clock $clk \
    -panel_name "Worst setup paths" -file "output_files/worst_paths_$n.rpt"
delete_timing_netlist
# -dont_export_assignments: project_close otherwise re-saves the .qsf
project_close -dont_export_assignments
