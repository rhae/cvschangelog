#-------------------------------------------------------------------------------
#  http://wiki.tcl.tk/3052
#
#  gp                        gnuplot
#  start and control gnuplot
#  Normally, all args are passed to gnuplot.
#  The following convenience function is applied: if the first argument is a
#  filename OR if the first argument is the command 'plot', then
#  - if filename contains wildcards (*), the youngest matching file is
#        selected
#  - the selected file is searched for lines containing "#! command"
#     - if such commands are found, these commands are sent to gnuplot
#     - otherwise, a plot command is sent to gnuplot
#-------------------------------------------------------------------------------
#  Examples:
#  gp filename            \   if filename contains wildcards (*),
#  gp 'filename'           \      select youngest file matching
#  gp plot filename        /  if file exists, try to read "#! commands"
#  gp plot 'filename'     /       from it
#  gp filename using 3:6  ->  plot 'filename' using 3:6
#  gp set title 'TEST'
#  gp replot
#  gp exit                ->  terminate gnuplot
#-------------------------------------------------------------------------------
proc gp { args } {
    global gnuplot gnuplot_rx

    set cmdline ""

    set argc [llength $args]

    set tryDaq         0
    if { $argc >= 2 && [lindex $args 0] == "plot" } {
        set tryDaq 1
    }

    #-----------------------------------------------------------------
    #  try to interpret arg as a filename
    #-----------------------------------------------------------------
    set filename [string trim [lindex $args $tryDaq] "'"]

    #-----------------------------------------------------------------
    #  convenience: if filename contains '*', look for youngest
    #        file matching pattern
    #-----------------------------------------------------------------
    if { [regexp {\*} $filename] } {
        set dir   [file dirname $filename]
        set mask  [file tail $filename]
        set files [glob -nocomplain -directory $dir -types f $mask]
        if { [llength $files] > 0 } {
            set filename [lindex $files 0]
            set filetime [file mtime $filename]
            foreach fname [lrange $files 1 end] {
                set mtime [file mtime $fname]
                if { $mtime > $filetime } {
                    set filename $fname
                    set filetime $mtime
                }
            }
        }
    }

    #-----------------------------------------------------------------
    #  check if arg is a filename, try to read "#! commands" from file
    #-----------------------------------------------------------------
    if { [file exist $filename] } {
        if { $argc <= 2 } {
            set f [open $filename "r"]
            while { [gets $f line] > -1 } {
                if { [regexp {^#!\s*(.*)} $line all cmd] } {         ;#
                    append cmdline "$cmd\n"
                }
            }
            close $f
            regsub -all {\$this} $cmdline $filename cmdline
        }
        if { $cmdline == "" } {
            set cmdline "plot '$filename'"
        }

        set cmdline "set title '$filename'\n$cmdline"
        foreach arg [lrange $args $tryDaq+1 end] { append cmdline "$arg " }
    }

    #-----------------------------------------------------------------
    #  build cmdline from args
    #-----------------------------------------------------------------
    if { $cmdline == "" } {
        foreach arg $args { append cmdline "$arg " }
    }

    #-----------------------------------------------------------------
    #  start gnuplot if not alread running
    #-----------------------------------------------------------------
    if { ![info exist gnuplot] } {
        set gpexe "D:/Programme/gnuplot/bin/wgnuplot_pipes.exe"
        set gpexe "D:/Programme/gnuplot/bin/gnuplot.exe"
        set gpexe "gnuplot"
        # gnuplot writes to stderr!
        set gnuplot [open "|$gpexe 2>@1" r+]
        fconfigure $gnuplot -buffering none
        fileevent  $gnuplot readable {
            #---------------------------------------------------------
            # async. background receive
            #---------------------------------------------------------
            if { [eof $gnuplot] } {
                puts stderr "# close gnuplot $gnuplot"
                close $gnuplot
                unset gnuplot
            } else {
                set rx [gets $gnuplot]
                if { $gnuplot_rx == "-" } {
                    puts stderr $rx        ;# 'gp' no longer waiting

                } else {
                    set gnuplot_rx $rx
                }
            }
        }
    }

    #-------------------------------------------------------------------
    #  send command to gnuplot
    #-------------------------------------------------------------------
    Log INFO "gnuplot> $cmdline"
    set gnuplot_rx ""
    puts $gnuplot "$cmdline\n"

    #-------------------------------------------------------------------
    #  wait 100ms if gnuplot writes a response
    #-------------------------------------------------------------------
    after 100 [list append gnuplot_rx ""]
    vwait gnuplot_rx
    set rx $gnuplot_rx
    set gnuplot_rx "-"        ;# show I'm not waiting any longer!
    Log VERBOSE $rx
    return $rx
}


if { [info script] eq $argv0 } {

    LogEnable INFO
    set Filename [file join [pwd] gp.png]

    gp set terminal pngcairo enhanced font \"arial,10\" fontscale 1.0 size 600, 400
    gp set output \"$Filename\"

    gp plot \[-10:10\] sin(x),atan(x),cos(atan(x))
    gp exit
}

