# Put the words of a .bin file into the ROM's block RAMs of a routed
# checkpoint, and write the bitstream, with no synthesis, placement, or
# routing (issue 122). The target rompatch of Makefile.inc runs it:
#
#    vivado -mode batch -source rompatch.tcl -tclargs top.dcp ref.bin new.bin top.bit
#
# ref.bin is the ROM that the checkpoint was built with, and new.bin the
# ROM to put in. Timing does not depend on the words of a block RAM, so
# the bitstream meets timing as the checkpoint did.
#
# The ROM (src/rom.vhd) has two banks, the even words and the odd ones,
# of C_BANK_WORDS words of 32 bits each. Synthesis splits each bank into
# block RAMs of a slice of the bits, here 2 bits of every address, and
# records the slice and the addresses of each in its properties
# ram_slice_begin, ram_slice_end, ram_addr_begin, and ram_addr_end. The
# bank comes from the cell's name (a_odd_reg or a_even_reg). A block RAM
# of width w holds 256 / w addresses in each of its 128 INIT strings, the
# lowest address in the lowest bits.
#
# Before it changes anything, the script stops when:
# - a bank's cells do not cover its bits 0 to 31 at every address exactly
#   once. Synthesis drops the block RAM of a slice that is 0 throughout
#   the ROM it was built with, and makes that bit a constant, so the
#   bitstream must then be built from nothing;
# - the INIT strings that it computes from ref.bin differ from those of
#   the checkpoint, so it got the layout or the reference wrong;
# - new.bin has a word beyond the ROM, which src/rom.vhd refuses too.
# Nothing is written then, and Vivado exits with an error.

# 2^G_ROM_ADDR_BITS words in all (src/system.vhd), half in each bank
set C_BANK_WORDS 16384

if {[llength $argv] != 4} {
   error "rompatch: give checkpoint ref.bin new.bin out.bit"
}
lassign $argv dcp refbin newbin outbit
set t0 [clock seconds]

# The words of a .bin file into the array named arr, by address
proc read_bin {name arr} {
   upvar $arr word
   global C_BANK_WORDS
   set f [open $name]
   while {[gets $f line] >= 0} {
      if {[scan $line "%x %x" a w] == 2} {
         if {$a >= 2 * $C_BANK_WORDS} {
            close $f
            error "rompatch: $name has a word at [format %08X $a], beyond the ROM"
         }
         set word($a) $w
      }
   }
   close $f
}

# The INIT string i of a block RAM, as 64 hex digits, from the words of arr
proc init_string {arr odd w sb ab i} {
   upvar $arr word
   set per  [expr {256 / $w}]
   set mask [expr {(1 << $w) - 1}]
   set v 0
   for {set k 0} {$k < $per} {incr k} {
      set a [expr {2 * ($ab + $i * $per + $k) + $odd}]
      if {[info exists word($a)]} {
         set v [expr {$v | ((($word($a) >> $sb) & $mask) << ($w * $k))}]
      }
   }
   # %064X cuts a 256-bit value short; %064llX does not
   return [format %064llX $v]
}

read_bin $refbin ref
read_bin $newbin new

open_checkpoint $dcp

set cells [get_cells -hier -filter {PRIMITIVE_TYPE =~ BMEM.*.* && NAME =~ *i_mem/*i_rom/*}]

# The layout of each cell, and the cover of each bank, bit, and address
set layout {}
foreach c $cells {
   set odd [string match *odd_reg* $c]
   if {!$odd && ![string match *even_reg* $c]} {
      error "rompatch: $c is in neither bank"
   }
   set w  [get_property READ_WIDTH_A $c]
   set sb [get_property ram_slice_begin $c]
   set se [get_property ram_slice_end $c]
   set ab [get_property ram_addr_begin $c]
   set ae [get_property ram_addr_end $c]
   if {$w ni {1 2 4} || $se - $sb + 1 != $w || $ae - $ab + 1 != 128 * 256 / $w} {
      error "rompatch: $c has width $w, bits $sb to $se, and addresses $ab to $ae, which are not handled"
   }
   for {set b $sb} {$b <= $se} {incr b} {
      lappend cover($odd,$b) [list $ab $ae]
   }
   lappend layout [list $c $odd $w $sb $ab]
}
foreach odd {0 1} {
   for {set b 0} {$b < 32} {incr b} {
      set next 0
      if {[info exists cover($odd,$b)]} {
         foreach r [lsort -integer -index 0 $cover($odd,$b)] {
            lassign $r ab ae
            if {$ab != $next} { break }
            set next [expr {$ae + 1}]
         }
      }
      if {$next != $C_BANK_WORDS} {
         error "rompatch: the block RAMs of bank $odd do not cover bit $b of every address once; build the bitstream from nothing"
      }
   }
}

# The check against the reference, then the patch
set bad 0
foreach l $layout {
   lassign $l c odd w sb ab
   for {set i 0} {$i < 128} {incr i} {
      set p [format INIT_%02X $i]
      set old [string toupper [lindex [split [get_property $p $c] h] 1]]
      if {$old ne [init_string ref $odd $w $sb $ab $i]} { incr bad }
   }
}
if {$bad} {
   error "rompatch: $bad INIT strings of the checkpoint differ from $refbin; build the bitstream from nothing"
}
puts "ROMPATCH: [llength $cells] cells match $refbin, [expr {[clock seconds] - $t0}] s"

set changed 0
foreach l $layout {
   lassign $l c odd w sb ab
   for {set i 0} {$i < 128} {incr i} {
      set p   [format INIT_%02X $i]
      set new_i [init_string new $odd $w $sb $ab $i]
      if {[string toupper [lindex [split [get_property $p $c] h] 1]] ne $new_i} {
         set_property $p 256'h$new_i $c
         incr changed
      }
   }
}
puts "ROMPATCH: $changed INIT strings changed for $newbin"

write_bitstream -force $outbit
puts "ROMPATCH: $outbit written, [expr {[clock seconds] - $t0}] s in all"
exit
