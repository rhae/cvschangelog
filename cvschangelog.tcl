#!/bin/tclsh

package require platform

source libs/log.tcl
source libs/gp.tcl
source libs/cvs.tcl

proc GetVersion {} {
  return "0.1"
}

namespace eval cvscl {
    variable Extensions
    variable Args

    array set Extensions [list \
        C/CPP  {.h .hpp .c .cpp} \
        FPGA   {.vhd .sym .sch .wcfg .xsvf .xise .mcs .ipf .ucf .cgc .cgp} \
        Images {.jpg .png .gif .jpeg } \
        Perl   {.pm .pl} \
        Html   {.htm .html} \
        Python {.py .pyc} \
        Tcl/Tk {.tcl} \
        Batch  {.cmd .cmd} \
    ]
}

proc cvscl::ReadFile { Filename } {
  set fd [open $Filename]
  set Lines [read $fd]
  close $fd
  return $Lines
}

#
#  Übernimmt die Programmargumente aus dem Array A
#
proc cvscl::SetArgs { ArgsVar } {
    upvar $ArgsVar A
    variable Args

    foreach {key val} [array get A] {
        set Args($key) $val
    }
}

proc IsTextFile { F } {
    set BinExt {.png .jpeg .jpg .xls .xlsx .gif .exe .dll .lib .xsvf}
    set Ext [string tolower [file extension $F]]
    if { $Ext in $BinExt } {
        return 0
    }
    return 1
}

proc CollectFileStats { Db Dir StatVar AllVersions } {
  upvar $StatVar Stat

  set BufSize [expr 512 * 1024]
  foreach F [cvs::GetFiles $Db $AllVersions] {

      set File [file join $Dir $F]
      set Ext [string tolower [file extension $File]]

      if { ![dict exists $Stat Extensions] } {
          dict lappend Stat Extensions $Ext
      } else {
          set Exts [dict get $Stat Extensions]
          if { $Ext ni $Exts } {
              dict lappend Stat Extensions $Ext
          }
      }
      dict incr Stat Files$Ext
      dict incr Stat Files-Total
      incr Cnt

      if { ![IsTextFile $File] } {
          puts "Do not count lines for $File"
          dict incr Stat BinFiles
          continue
      }

      try {
          set fd [open $File]
          fconfigure $fd -buffersize $BufSize -translation binary
          set FCnt 0
          while {![eof $fd]} {
              set str [read $fd $BufSize]
              set FCnt [expr { $FCnt + [string length $str]-[string length [string map {\n {}} $str]]}]
          }
          close $fd
          # puts [format {File %s: %d lines} [file tail $File] $FCnt]
          dict incr Stat SLOC$Ext $FCnt
          dict incr Stat SLOC-total $FCnt

          dict set Stat [file join $Dir $File] $FCnt
          dict lappend Stat _Files [file join $Dir $File]
      } on error {results options} {
      }
  }

  return $Cnt
}

proc pdict {dict {pattern *}} {
   set longest [tcl::mathfunc::max 0 {*}[lmap key [dict keys $dict $pattern] {string length $key}]]
   dict for {key value} [dict filter $dict key $pattern] {
      puts [format "%-${longest}s = %s" $key $value]
   }
}

proc cvscl::DescrByFileExt { Ext } {
    variable Extensions 

    foreach {Descr Exts} [array get Extensions] {
        if { $Ext in $Exts } {
            return $Descr
        }
    }

    return "Misc"
}

proc cvscl::ChartCodeSize { Db Repo InitialSize } {

  set Filename [GetFilename $Repo "_codesize.png"]
  set fd [open codesize.csv w+]

  set Size $InitialSize

  $Db eval {
    SELECT date, lines FROM commits ORDER BY strftime('%s', date) ASC;
  } {
    lassign [split $lines " "] added removed
    set Size [expr $Size + $added + $removed]

    puts $fd [format {%s;%s} $date $Size]
  }
  close $fd

  gp set terminal pngcairo font \"Helvetica,10\" size 600,300 enhanced
  gp set output "'$Filename'"
  gp set datafile separator "';'"
  gp set style line 101 lc rgb "'#808080'" lt 1 lw 1
  gp set border 3 front ls 101
  gp set tics nomirror out scale 0.75

  gp set style line 1 lw 2 lc rgb '#0099ff'

  gp set style data steps
  gp set timefmt "'%Y-%m-%d %H:%M:%S'"
  gp set xdata time
  gp unset key

  gp set format x "\"%d.%b\\n%Y\""
  gp set grid
  gp plot "'codesize.csv' " using 1:2 ls 1
  gp exit
  
  return $Filename
}

proc cvscl::RepoInfo { Db Repo Branch } {

  set Html {
    <div class="w3-container w3-content">
        <div class="w3-panel w3-x-blue-st">
          <p>CVS-Repository</p>
        </div>
  
        <table class="w3-table-all w3-small">
  }

  # TODO RLOGfile
  set Infos [list \
    "Erstellt am"   [clock format [clock seconds] -format "%Y-%m-%d %H:%M:%S"] \
    CVSROOT         $cvs::Data(CVSROOT) \
    Repository      $Repo \
    Branch          $Branch \
  ]

  foreach { Title Value } $Infos {
    append Html "<tr><td>$Title</td><td>$Value</td></tr>"
  }
  append Html "</table>\n</div>"
  return $Html
}

proc pdict {dict {pattern *}} {
   set longest 0
   dict for {key -} $dict {
      if {[string match $pattern $key]} {
         set longest [expr {max($longest, [string length $key])}]
      }
   }
   dict for {key value} [dict filter $dict key $pattern] {
      puts [format "%-${longest}s = %s" $key $value]
   }
}

proc cvscl::Overview { Db Repo Branch } {
  set Dir [cvs::get $Repo -dir]
  cvs::checkout $Repo
  cvs::update $Db $Dir 1.1

  set ::Stat [dict create]
  CollectFileStats $Db $Dir ::Stat 0
  #pdict $::Stat
  set InitialSize [dict get $::Stat SLOC-total]
  set Size $InitialSize
  puts "Initial line count of repo: $InitialSize"
  
  set DirLen [string length $Dir]
  foreach F [dict get $::Stat _Files] {
    set Cnt [dict get $::Stat $F]
    set File [string range $F $DirLen+1 end]
    cvs::UpdateLineCnt $Db $File 1.1 $Cnt
  }

  set FilesTotal [dict get $::Stat Files-Total]
  set MiscFiles 0
  array set FileStat [list]
  foreach Ext [dict get $::Stat Extensions] {
    set Bucket   [DescrByFileExt $Ext]
    set FilesExt [dict get $::Stat Files$Ext]
    incr FileStat($Bucket) $FilesExt
  }

  append Html {
    <div class="w3-container w3-content">
      <div class="w3-panel w3-x-blue-st">
        <p>&Uuml;bersicht</p>
      </div>    

      <table class="w3-table-narrow-all w3-tiny">
      <colgroup>
        <col style="width:10%">
        <col style="width:15%;padding-right: 16px">
        <col style="width:15%;padding-right: 16px">
        <col style="width:75%">
      </colgroup>
  }
  append Html [format {
    <tr class="w3-dark-grey">
      <th>%s</th>
      <th>%s</th>
      <th>%s</th>
      <th></th>
    </tr>
  } "Dateityp" "Anzahl absolut" "Anzahl prozentual"]

  foreach {Bucket FileCnt} [lsort -stride 2 -index 1 -integer -decreasing [array get FileStat]] {
      set Percent [expr {$FileCnt * 100.0 / $FilesTotal}]
      puts "$Bucket  $Percent"
      append Html [format {
        <tr>
            <td>%s</td>
            <td class="w3-right-align">%s<span style="padding-right:32px"> </span></td>
            <td class="w3-right-align">%.1f %%<span style="padding-right:32px"> </span></td>
            <td></td>
        </tr>
      } $Bucket $FileCnt $Percent]
  }

  append Html [format {
        <tr>
            <td>%s</td>
            <td class="w3-right-align">%s<span style="padding-right:32px"> </span></td>
            <td class="w3-right-align"><span style="padding-right:32px"> </span></td>
            <td></td>
        </tr>
  } Gesamt $FilesTotal]

  append Html </table> </div>
}

proc cvscl::CodeSize { Db Repo } {

  set ::Stat [dict create]
  CollectFileStats $Db [cvs::get $Repo -dir] ::Stat 1
  set FilesTotal [dict get $::Stat Files-Total]
  set FNCodeSize [ChartCodeSize $Db $Repo [dict get $::Stat Files-Total]]

  set Html [format {
    <div class="w3-container w3-content">
      <div class="w3-panel w3-x-blue-st">
        <p>Codegr&ouml;&szlig;e</p>
      </div>

      <div class="w3-container">
          <img src="%s" class="w3-x-img-center">
      </div>
    </div>
  } $FNCodeSize]

  return $Html
}

proc cvscl::ActivityByDev { Db } {
  append Html {<div class="w3-container w3-content">
      <div class="w3-panel w3-x-blue-st">
        <p>Entwickler-Aktivität</p>
      </div>
      <table class="w3-table-narrow-all w3-tiny">
      <colgroup>
        <col style="width:10%">
        <col style="width:10%">
        <col style="width:10%">
        <col style="width:15%;padding-right: 16px">
        <col style="width:55%">
      </colgroup>
  }
  append Html [format {
    <tr class="w3-dark-grey">
      <th>%s</th>
      <th>%s</th>
      <th>%s</th>
      <th>%s</th>
      <th>%s</th>
    </tr>
  } "Entwickler" "Änderungen absolut (alle)" "Änderungen prozentual (alle)" "Änderungen (unterschiedliche Dateien)" "Letzte Änderung"]

  array set ModifiedAll [cvs::GetFileCntModified $Db "all" HEAD]
  array set ModifiedDistinct [cvs::GetFileCntModified $Db "distinct" HEAD]
  array set LastCommit [cvs::GetLastCommit $Db]

  set TotalCommits 0
  foreach Author [cvs::GetAuthors $Db] {
    incr TotalCommits $ModifiedAll($Author)
  }

  foreach { Author X } [lsort -stride 2 -index 1 -decreasing -integer [array get ModifiedAll]] {
    set Percentage [expr $ModifiedAll($Author).0 / $TotalCommits * 100]
    append Html [format {
      <tr>
        <td>%s</td>
        <td class="w3-right-align">%s<span style="padding-right:32px"> </span></td>
        <td class="w3-right-align">%2.1f %%<span style="padding-right:32px"> </span></td>
        <td class="w3-right-align">%s<span style="padding-right:32px"> </span></td>
        <td>%s</td>
      </tr>
    } $Author $ModifiedAll($Author) $Percentage $ModifiedDistinct($Author) $LastCommit($Author)]
  }

  append Html {</table></div>}
}

proc cvscl::CheckinByDeveloper { Db } {

  set fd [open commit_dev.csv w+]
  set Total 0
  array set Stat [list]
  $Db eval {
    SELECT author, COUNT(*) FROM commits GROUP BY author;
  } {
    set author [string map {"\\" {}} $author]
    puts $fd [format {%s;%s} $author $COUNT(*)]
    set Stat($author) $COUNT(*)
    incr Total $COUNT(*)
  }
  close $fd

 return {
    <div class="w3-container w3-content">
      <div class="w3-panel w3-x-blue-st">
        <p>Checkin nach Entwickler</p>
      </div>

      <div class="w3-container">
          <img src="commit_dev.png" class="w3-x-img-center">
      </div>
    </div>
  }
}

proc cvscl::IsOnBranch { Revision Branch } {

  if { $Branch eq "HEAD" } {
    set _MaxSplits 2
    set _Rev ""
  } else {
    error "only HEAD is supported"
  }

  if { [llength [split $Revision "."]] == $_MaxSplits } {
    return true
  }

  if { $_Rev != "" && [string match ${_Rev}* $Revision] } {
      return true
  }

  return false
}

proc cvscl::CheckinList { fd Db MaxCommits {Branch HEAD}} {

  puts $fd {<div class="w3-container w3-content">
        <div class="w3-panel w3-x-blue-st">
          <p>Checkins</p>
        </div>
        <input class="w3-input w3-border w3-padding" type="text" placeholder="Search in checkins.." id="myInput" onkeyup="myFunction()">
        <br>
        <table class="w3-table-narrow-all w3-tiny" id="myTable">
          <col style="width:9%">
          <col style="width:5%">
          <col style="width:12%">
          <col style="width:30%">
          <col style="width:44%">
        <tr class="w3-dark-grey">
          <th>Datum</th>
          <th>Autor</th>
          <th>Tag</th>
          <th>Dateien</th>
          <th>Kommentar</th>
        </tr>
  }

  array set DateTagMap [list]
  cvs::GetTagsByDate $Db DateTagMap
  #parray DateTagMap

  set LastCommit ""
  set Files [list]
  set CheckIn ""
  set LastComment ""
  set LastDate ""
  set CommitCnt 0
  $Db eval {
    SELECT * FROM commits ORDER BY date DESC;
  } {

    if { ![IsOnBranch $revision $Branch] } {
      continue
    }

    set FullDate $date
    set date [lindex [split $date] 0]

    if { $LastCommit eq "" } {
      set Tag ""
      if { $FullDate in [array names DateTagMap] } {

        set Tags $DateTagMap($FullDate)
        set Cnt [llength $Tags]

        for {set i 0 } { $i < $Cnt } { incr i } {
          set T [lindex $Tags $i]
          append Tag [format {<div class="w3-x-tag w3-black">%s</div>} $T]
          if { $i+1 < $Cnt } {
            append Tag {<br />}
          }
        }
      }

      set CheckIn [format {<tr>
          <td>%s</td>
          <td>%s</td>
          <td>%s</td>
          <td>} $date $author $Tag]
      set LastDate [lindex [split $date] 0]
      set LastComment $comment
      set LastCommit $commitid
    }

    if { $LastCommit != $commitid } {
      incr CommitCnt
      if { $CommitCnt == $MaxCommits } {
        break;
      }

      foreach Item [lsort -index 0 $Files] {
        lassign $Item File Version Changed
        append CheckIn "\n" $File " " $Version " " $Changed "<br>"
      }
      append CheckIn [format {
          </td>
          <td>%s</td>
        </tr>} $LastComment]
      puts $fd $CheckIn

      #set DateHtml [format {<span class="w3-text-blue">%s</span>} $date]
      set DateHtml $date
      if { $date eq $LastDate } {
        set DateHtml [format {<span class="w3-x-grey-st">%s</span>} $date]
      }
      set LastDate $date

      set Tag ""
      if { $FullDate in [array names DateTagMap] } {
        set Tags $DateTagMap($FullDate)
        set Cnt [llength $Tags]

        for {set i 0 } { $i < $Cnt } { incr i } {
          set T [lindex $Tags $i]
          append Tag [format {<div class="w3-x-tag w3-black">%s</div>} $T]
          if { $i+1 < $Cnt } {
            append Tag {<br />}
          }
        }
      }
      set CheckIn [format {        <tr>
          <td>%s</td>
          <td>%s</td>
          <td>%s</td>
          <td>} $DateHtml $author $Tag]

      set LastComment $comment
      set LastCommit $commitid
      unset Files
      set Files [list]
    }

    lappend Files [list $file $revision $lines]
  }

  foreach Item [lsort -index 0 $Files] {
    lassign $Item File Version Changed
    append CheckIn "\n" $File " " $Version " " $Changed "<br>"
  }
  append CheckIn [format {
      </td>
      <td>%s</td>
    </tr>} $LastComment]
  puts $fd $CheckIn

  puts $fd {
    </table>
  </div>}

}

proc cvscl::Tags { Db {MaxTags 20} } {
  array set DateTagMap [list]
  cvs::GetTagsByDate $Db DateTagMap
  
  append Html {
      <div class="w3-container w3-content">
        <div class="w3-panel w3-x-blue-st">
          <p>Tags</p>
        </div>

        <table class="w3-table-narrow-all w3-tiny">
        <col width="200px">
        <col>
        <tr class="w3-dark-grey">
          <th>Tag</th>
          <th>Datum</th>
        </tr>
  }
  
  set TagCnt 0
  foreach {FullDate Tags} [lsort -stride 2 -index 0 -decreasing [array get DateTagMap]] {
    incr TagCnt
    if { $TagCnt > $MaxTags } {
      break;
    }
    lassign [split $FullDate " "] Date

    append Html [format {<tr><td>%s</td><td>%s</td></tr>} [join $Tags {<br />}] $Date] "\n"
  }
  append Html {</table>
    </div>}
}

proc cvscl::GetFilename { Repo Ext } {
  variable Args

  set Postfix ""
  if { $Args(only) ne "" } {
    set Postfix "_"
    append Postfix [string map {{*} {} : {} {\\} _ / _} $Args(only)]
  }

  append FN $Repo $Postfix $Ext
  return $FN
}

proc cvscl::changelog { Repo Branch commentfilter OnlyDirFile } {
  variable Data

  set Ret [cvs::rlog2sql $Repo $commentfilter $OnlyDirFile]
  if { $Ret < 0 } {
    return $Ret
  }

  set Db cvsdb
  sqlite3 $Db [cvs::GetDbFile $Repo]

  set Css [ReadFile w3c.css]
  append Css {.w3-x-img-center{display:block;margin-left: auto; margin-right:auto}} "\n"
  append Css {.w3-x-blue-st{color:#fff!important;background-color: #009ce2}} "\n"
  append Css {.w3-x-grey-st{color:#adadad!important}} "\n"
  append Css {.w3-x-tag{background-color:#000;color:#fff;display:inline-block;padding-left:4px;padding-right:4px;text-align:center;font-size:6pt}} "\n"

  append Css {
    .w3-table-narrow,.w3-table-narrow-all{border-collapse:collapse;border-spacing:0;width:100%;display:table}.w3-table-narrow-all{border:1px solid #ccc}
    .w3-bordered tr,.w3-table-narrow-all tr{border-bottom:1px solid #ddd}.w3-striped tbody tr:nth-child(even){background-color:#f1f1f1}
    .w3-table-narrow-all tr:nth-child(odd){background-color:#fff}.w3-table-narrow-all tr:nth-child(even){background-color:#f1f1f1}
    .w3-table-narrow td,.w3-table-narrow th,.w3-table-narrow-all td,.w3-table-narrow-all th{padding:4px 4px;display:table-cell;text-align:left;vertical-align:top}
    .w3-table-narrow th:first-child,.w3-table-narrow td:first-child,.w3-table-narrow-all th:first-child,.w3-table-narrow-all td:first-child{padding-left:8px}
  }

  set Header [format {<!DOCTYPE html>
<html>
<head>
<title>Changelog %s</title>
<meta charset="utf-8" /> 
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
%s
</style>
} $Repo $Css]

  set Filename [GetFilename $Repo ".html"]
  set Html [open $Filename "w+"]

  puts $Html $Header
  puts $Html <body>
  puts $Html [RepoInfo $Db $Repo $Branch]
  puts $Html [Overview $Db $Repo $Branch]
  puts $Html [CodeSize $Db $Repo]
  puts $Html [ActivityByDev $Db]
  puts $Html [Tags $Db]
  #puts $Html [CheckinByDeveloper $Db]
  CheckinList $Html $Db 250
  puts $Html [format {<div class="w3-container w3-content">
    <div class="w3-panel w3-border-top">
      <div class="w3-small w3-center">cvschangelog.tcl - %s</div>
    </div>
  </div>} [GetVersion]]

  puts $Html {
    <script>
    function myFunction() {
      var input, filter, table, tr, td, i, j, found;
      input = document.getElementById("myInput");
      filter = input.value.toUpperCase();
      table = document.getElementById("myTable");
      tr = table.getElementsByTagName("tr");
      for (i = 1; i < tr.length; i++) {
        td = tr[i].getElementsByTagName("td");
        found = false;
        for( j = 0; j < td.length; j++ ) {
          
          if (td[j]) {
            if (td[j].innerHTML.toUpperCase().indexOf(filter) > -1) {
              found = true;
            }
          }
        }
        tr[i].style.display = found ? "" : "none";
      }
    }
    </script>
  }
  puts $Html </body>
  puts $Html </html>

  close $Html
}


proc commentfilter { Comment } {
  set Idx [string first "Committed on the Free" $Comment]
  if { $Idx > 0 } {
    return [string range $Comment 0 $Idx-1]
  }
  return $Comment
}

#
#  Hauptprogramm
#
#  Liest das CSV-Repository ein und erzeugt das CVS-Changelog als HTML-Datei.
#  Die CVS-Versionsangaben werden aus der RLOG-Datei gelesen und in eine sqlite
#  DB gespeichert.
#
proc main { argv } {

  set ArgIdx 0
  set ArgMax [llength $argv]
  array set Args [list]
  set Args(module) ""
  set Args(branch) "HEAD"
  set Args(cvsroot) $::cvs::Data(CVSROOT)
  set Args(output) "buildhtmlreport"
  set Args(ignore) ""
  set Args(rlogfile) ""
  set Args(commentfilter) ""
  set Args(only) ""

  puts [format {cvschangelog.tcl - %s} [GetVersion]]

  while { $ArgIdx < $ArgMax } {
    
    set Argument [lindex $argv $ArgIdx]
    incr ArgIdx
    if { [string match "-m=*" $Argument] || [string match "-module=*" $Argument] } {
      set Args(module) [lindex [split $Argument "="] 1]
    } elseif { [string match "-branch=*" $Argument] } {
      set Args(branch) [lindex [split $Argument "="] 1]
    } elseif { [string match "-d" $Argument] } {
      set Args(cvsroot) [lindex $argv $ArgIdx]
    } elseif { [string match "-ouput=*" $Argument] } {

      set Args(output) [lindex [split $Argument "="] 1]
    } elseif { [string match "-dir=*" $Argument] } {

      set Args(output) [lindex [split $Argument "="] 1]
    } elseif { [string match "-ignore=*" $Argument] } {

      set value [lindex [split $Argument "="] 1]
      set Args(ignore) [split $value ","]
    } elseif { [string match "-rlogfile=*" $Argument] } {

      set value [lindex [split $Argument "="] 1]
      set Args(rlogfile) [split $value ","]
    } elseif { [string match "-only=*" $Argument] } {

      set Args(only) [lindex [split $Argument "="] 1]
    }
  }

  if { $Args(module) eq "" } {
    puts stderr "No module specified. Use -m=<Modulename>"
    exit 1
  }
  set cvs::Data(CVSROOT) $Args(cvsroot)
  cvscl::SetArgs Args

  if { $Args(output) ne "buildhtmlreport" } {
    puts stderr "Invalid output format. Valid formats are: buildhtmlreport"
    exit 1
  }

  #parray Args
  #parray cvs::Data

  try {
    file delete -force [cvs::GetDbFile $Args(module)]
  } on error {results options } {
    puts "ERROR file delete $results"
  }

  cvscl::changelog $Args(module) $Args(branch) commentfilter $Args(only)
}

main $argv
