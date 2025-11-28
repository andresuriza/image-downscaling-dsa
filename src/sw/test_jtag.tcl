# ============================================
# Quartus System Console Test Script
# Tests JTAG-to-Avalon communication with 
# the image downscaler accelerator
# ============================================

# Base addresses
set SDRAM_BASE        0x00000000
set CSR_BASE          0x04000000
set CSR_RAM_BASE      0x04004000

# CSR Register offsets
set CSR_CTRL          0x000
set CSR_STATUS        0x004
set CSR_IN_WIDTH      0x008
set CSR_IN_HEIGHT     0x00C
set CSR_OUT_WIDTH     0x010
set CSR_OUT_HEIGHT    0x014
set CSR_SCALE_Q8_8    0x018
set CSR_MODE          0x01C
set CSR_PROGRESS      0x020
set CSR_ERRORS        0x024
set CSR_PERF_FLOPS_LO 0x040
set CSR_PERF_CYCLES_LO 0x058
set CSR_VERSION       0x0FC

# ============================================
# Utility Procedures
# ============================================

proc csr_addr {offset} {
    global CSR_BASE
    return [expr {$CSR_BASE + $offset}]
}

proc connect_jtag {} {
    puts "Connecting to JTAG master..."
    set masters [get_service_paths master]
    if {[llength $masters] == 0} {
        puts "ERROR: No JTAG masters found!"
        return ""
    }
    set master [lindex $masters 0]
    open_service master $master
    puts "Connected to: $master"
    return $master
}

proc disconnect_jtag {master} {
    close_service master $master
    puts "Disconnected from JTAG master"
}

# ============================================
# Test Procedures
# ============================================

proc test_version {master} {
    global CSR_VERSION
    puts "\n--- Testing Version Register ---"
    set version [master_read_32 $master [csr_addr $CSR_VERSION] 1]
    puts "Version: [format 0x%08X $version]"
    if {$version == 0x00010000} {
        puts "Version OK (v1.0)"
        return 1
    } else {
        puts "WARNING: Unexpected version!"
        return 0
    }
}

proc test_csr_readwrite {master} {
    global CSR_IN_WIDTH CSR_IN_HEIGHT CSR_OUT_WIDTH CSR_OUT_HEIGHT
    global CSR_SCALE_Q8_8 CSR_MODE
    
    puts "\n--- Testing CSR Read/Write ---"
    
    # Write test values
    puts "Writing configuration registers..."
    master_write_32 $master [csr_addr $CSR_IN_WIDTH] 512
    master_write_32 $master [csr_addr $CSR_IN_HEIGHT] 512
    master_write_32 $master [csr_addr $CSR_OUT_WIDTH] 256
    master_write_32 $master [csr_addr $CSR_OUT_HEIGHT] 256
    master_write_32 $master [csr_addr $CSR_SCALE_Q8_8] 0x0080  ;# 0.5 in Q8.8
    master_write_32 $master [csr_addr $CSR_MODE] 0
    
    # Read back
    puts "Reading back..."
    set in_w [master_read_32 $master [csr_addr $CSR_IN_WIDTH] 1]
    set in_h [master_read_32 $master [csr_addr $CSR_IN_HEIGHT] 1]
    set out_w [master_read_32 $master [csr_addr $CSR_OUT_WIDTH] 1]
    set out_h [master_read_32 $master [csr_addr $CSR_OUT_HEIGHT] 1]
    set scale [master_read_32 $master [csr_addr $CSR_SCALE_Q8_8] 1]
    set mode [master_read_32 $master [csr_addr $CSR_MODE] 1]
    
    puts "  IN_WIDTH:  $in_w (expected 512)"
    puts "  IN_HEIGHT: $in_h (expected 512)"
    puts "  OUT_WIDTH: $out_w (expected 256)"
    puts "  OUT_HEIGHT: $out_h (expected 256)"
    puts "  SCALE:     [format 0x%04X $scale] (expected 0x0080)"
    puts "  MODE:      $mode (expected 0)"
    
    if {$in_w == 512 && $in_h == 512 && $out_w == 256 && $out_h == 256 && $scale == 0x0080} {
        puts "CSR Read/Write OK"
        return 1
    } else {
        puts "ERROR: CSR mismatch!"
        return 0
    }
}

proc test_csr_ram {master} {
    global CSR_RAM_BASE
    
    puts "\n--- Testing CSR RAM ---"
    
    # Write test pattern
    puts "Writing test pattern to CSR RAM..."
    for {set i 0} {$i < 16} {incr i} {
        set addr [expr {$CSR_RAM_BASE + $i * 4}]
        set data [expr {0xDEAD0000 + $i}]
        master_write_32 $master $addr $data
    }
    
    # Read back
    puts "Reading back..."
    set pass 1
    for {set i 0} {$i < 16} {incr i} {
        set addr [expr {$CSR_RAM_BASE + $i * 4}]
        set expected [expr {0xDEAD0000 + $i}]
        set actual [master_read_32 $master $addr 1]
        if {$actual != $expected} {
            puts "ERROR at offset $i: expected [format 0x%08X $expected], got [format 0x%08X $actual]"
            set pass 0
        }
    }
    
    if {$pass} {
        puts "CSR RAM OK"
    }
    return $pass
}

proc test_sdram {master} {
    global SDRAM_BASE
    
    puts "\n--- Testing SDRAM ---"
    
    # Write test pattern
    puts "Writing test pattern to SDRAM..."
    for {set i 0} {$i < 16} {incr i} {
        set addr [expr {$SDRAM_BASE + $i * 4}]
        set data [expr {0xCAFE0000 + $i}]
        master_write_32 $master $addr $data
    }
    
    # Read back
    puts "Reading back..."
    set pass 1
    for {set i 0} {$i < 16} {incr i} {
        set addr [expr {$SDRAM_BASE + $i * 4}]
        set expected [expr {0xCAFE0000 + $i}]
        set actual [master_read_32 $master $addr 1]
        if {$actual != $expected} {
            puts "ERROR at offset $i: expected [format 0x%08X $expected], got [format 0x%08X $actual]"
            set pass 0
        }
    }
    
    if {$pass} {
        puts "SDRAM OK"
    }
    return $pass
}

proc test_status {master} {
    global CSR_STATUS CSR_PROGRESS CSR_ERRORS
    
    puts "\n--- Reading Status ---"
    set status [master_read_32 $master [csr_addr $CSR_STATUS] 1]
    set progress [master_read_32 $master [csr_addr $CSR_PROGRESS] 1]
    set errors [master_read_32 $master [csr_addr $CSR_ERRORS] 1]
    
    puts "  STATUS:   [format 0x%08X $status]"
    puts "    BUSY:   [expr {($status & 1) ? "Yes" : "No"}]"
    puts "    DONE:   [expr {($status & 2) ? "Yes" : "No"}]"
    puts "  PROGRESS: $progress pixels"
    puts "  ERRORS:   $errors"
}

# ============================================
# Main Test Sequence
# ============================================

proc run_all_tests {} {
    puts "============================================"
    puts "Image Downscaler JTAG Test Suite"
    puts "============================================"
    
    set master [connect_jtag]
    if {$master == ""} {
        return
    }
    
    set pass 1
    set pass [expr {$pass && [test_version $master]}]
    set pass [expr {$pass && [test_csr_readwrite $master]}]
    set pass [expr {$pass && [test_csr_ram $master]}]
    set pass [expr {$pass && [test_sdram $master]}]
    test_status $master
    
    disconnect_jtag $master
    
    puts "\n============================================"
    if {$pass} {
        puts "ALL TESTS PASSED"
    } else {
        puts "SOME TESTS FAILED"
    }
    puts "============================================"
}

# Run tests
run_all_tests
