
namespace eval Log {
  array set LogLevels [list DEBUG 1 VERBOSE 2 INFO 3 WARN 4 ERROR 5]
  set LogLevel 0
}

proc Log { level msg } {
    variable Log::LogLevels
    variable Log::LogLevel

    if { !$LogLevel } {
        #puts "XX: LogLevel == 0"
        return
    }

    set Level $LogLevels($level)
    if { $Level < $LogLevel } {
        # puts "XX: Level ($Level) < LogLevel ($LogLevel)"
        return
    }

    if { [string trim $msg] eq "" } {
        return
    }

    #puts [format {[%s] %s} $level $msg]
    puts [format {%s} $msg]
}

proc LogEnable { level } {
    variable Log::LogLevels
    variable Log::LogLevel

    set LogLevel $LogLevels($level)
}

LogEnable VERBOSE