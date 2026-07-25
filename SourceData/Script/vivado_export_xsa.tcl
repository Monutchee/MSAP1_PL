set project [current_project]

if {$project eq ""} {
    error "No Vivado project is currently open."
}

set project_dir  [get_property DIRECTORY $project]
set project_name [get_property NAME $project]

set output_dir [file normalize \
    [file join $project_dir .. .. runtime-generated bin_file]]

set output_file [file join $output_dir "${project_name}.xsa"]

file mkdir $output_dir

puts "Exporting hardware platform:"
puts "  Project: $project_name"
puts "  Output:  $output_file"

write_hw_platform \
    -fixed \
    -include_bit \
    -force \
    -file $output_file

puts "XSA export completed."