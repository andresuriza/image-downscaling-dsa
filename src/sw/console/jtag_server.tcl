# Persistent JTAG server script for system-console
# Reads commands from stdin, executes them, writes results to stdout
# Protocol: Each command ends with newline, response ends with "###END###\n"

# Disable buffering
fconfigure stdout -buffering line
fconfigure stdin -buffering line

# Open master connection once
set masters [get_service_paths master]
if {[llength $masters] == 0} {
    puts "ERROR: No JTAG masters found"
    puts "###END###"
    flush stdout
    return
}

set m [lindex $masters 0]
open_service master $m
puts "JTAG_OK: Connected"
puts "###END###"
flush stdout

# Command loop
while {1} {
    if {[eof stdin]} {
        break
    }
    
    set line [gets stdin]
    if {$line eq ""} {
        continue
    }
    
    # Parse command
    set parts [split $line " "]
    set cmd [lindex $parts 0]
    
    if {[catch {
        switch $cmd {
            "READ32" {
                # READ32 <addr>
                set addr [lindex $parts 1]
                set val [master_read_32 $m $addr 1]
                puts $val
            }
            "WRITE32" {
                # WRITE32 <addr> <value>
                set addr [lindex $parts 1]
                set val [lindex $parts 2]
                master_write_32 $m $addr $val
                puts "OK"
            }
            "READMEM" {
                # READMEM <addr> <len>
                set addr [lindex $parts 1]
                set len [lindex $parts 2]
                set data [master_read_memory $m $addr $len]
                puts $data
            }
            "WRITEMEM" {
                # WRITEMEM <addr> <hex_bytes...>
                set addr [lindex $parts 1]
                set data [lrange $parts 2 end]
                master_write_memory $m $addr $data
                puts "OK"
            }
            "QUIT" {
                puts "OK: Closing"
                puts "###END###"
                flush stdout
                break
            }
            "PING" {
                puts "PONG"
            }
            default {
                puts "ERROR: Unknown command $cmd"
            }
        }
    } err]} {
        puts "ERROR: $err"
    }
    
    puts "###END###"
    flush stdout
}

# Cleanup
catch {close_service master $m}
