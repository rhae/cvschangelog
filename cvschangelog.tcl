#!/bin/tclsh

package require platform

source libs/gp.tcl
source libs/cvs.tcl

proc GetVersion {} {
  return "0.1"
}

namespace eval cvscl {
    variable Extensions

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

proc IsTextFile { F } {
    set BinExt {.png .jpeg .jpg .xls .xlsx .gif .exe .dll .lib .xsvf}
    set Ext [string tolower [file extension $F]]
    if { $Ext in $BinExt } {
        return 0
    }
    return 1
}

proc _CollectFileStats { Dir LevelVar StatVar } {
  upvar $LevelVar Level
  upvar $StatVar Stat

  set OldDir [pwd]
  cd $Dir

  incr Level
  #puts "Level $Level"

  set Cnt 0
  set Dir2 ""
  foreach _Dir [glob -nocomplain -types d *] {
    set Dir2 [file join $Dir $_Dir]
    set Cnt [_CollectFileStats  $Dir2 $LevelVar $StatVar]

      if { $Level < 2 } {
          #puts "xx Dir $Dir2"
          dict lappend Stat SubDirs $Dir2
          dict incr Stat $Dir2.Files $Cnt
      }
  }


  set Files [glob -nocomplain -types f *]
  if { $Files eq "" } {
      cd $OldDir
      incr Level -1
      return $Cnt
  }

  set BufSize [expr 512 * 1024]
  foreach File $Files {

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

      if { $Level < 2 } {
          #puts "yy Dir $Dir2"
          dict incr Stat $Dir2.Files
      }
  }

  incr Level -1
  cd $OldDir
  return $Cnt
}

proc pdict {dict {pattern *}} {
   set longest [tcl::mathfunc::max 0 {*}[lmap key [dict keys $dict $pattern] {string length $key}]]
   dict for {key value} [dict filter $dict key $pattern] {
      puts [format "%-${longest}s = %s" $key $value]
   }
}

proc CollectFileStats { Dir StatVar } {
    set Level 0
    _CollectFileStats $Dir Level $StatVar
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

  set Filename [format {%s_codesize.png} $Repo]
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

proc cvscl::CodeSize { Db Repo } {

  set Dir [cvs::checkout $Repo]
  cvs::update $Dir 1.1

  set ::Stat [dict create]
  CollectFileStats $Dir ::Stat
  set InitialSize [dict get $::Stat SLOC-total]
  set Size $InitialSize
  puts "Initial line count of repo: $InitialSize"
  # pdict $::Stat

  set FilesTotal [dict get $::Stat Files-Total]
  set MiscFiles 0
  array set FileStat [list]
  foreach Ext [dict get $::Stat Extensions] {
    set Bucket   [DescrByFileExt $Ext]
    set FilesExt [dict get $::Stat Files$Ext]
    incr FileStat($Bucket) $FilesExt
  }
  parray FileStat

  set FNCodeSize [ChartCodeSize $Db $Repo [dict get $::Stat Files-Total]]

  set Html [format {
    <div class="w3-container w3-content">
      <div class="w3-panel w3-x-blue-st">
        <p>Codegr&ouml;&szlig;e</p>
      </div>

      <div class="w3-container">
          <img src="%s" class="w3-x-img-center">
      </div>
  } $FNCodeSize]


  append Html {
      <div class="w3-container">
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

  array set ModifiedAll [cvs::GetFileCntModified $Db "all"]
  array set ModifiedDistinct [cvs::GetFileCntModified $Db "distinct"]
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

proc cvscl::CheckinList { fd Db } {

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
  set MaxCommits 100
  set CommitCnt 0
  $Db eval {
    SELECT * FROM commits ORDER BY date DESC;
  } {
    set FullDate $date
    set date [lindex [split $date] 0]

    if { $LastCommit eq "" } {
      set Tag ""
      if { $FullDate in [array names DateTagMap] } {
        set Tag [format {<div class="w3-x-tag w3-black">%s</div>} $DateTagMap($FullDate)]
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
        set Tag [format {<div class="w3-x-tag w3-black">%s</div>} $DateTagMap($FullDate)]
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
  foreach {FullDate Tag} [lsort -stride 2 -index 0 -decreasing [array get DateTagMap]] {
    incr TagCnt
    if { $TagCnt > $MaxTags } {
      break;
    }
    lassign [split $FullDate " "] Date
    append Html [format {<tr><td>%s</td><td>%s</td></tr>} $Tag $Date] "\n"
  }
  append Html {</table>
    </div>}
}

proc cvscl::changelog { Repo Branch commentfilter } {
  variable Data

  set Ret [cvs::rlog2sql $Repo $commentfilter]
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

  set Filename ${Repo}.html
  set Html [open $Filename "w+"]

  puts $Html $Header
  puts $Html <body>
  puts $Html [RepoInfo $Db $Repo $Branch]
  puts $Html [CodeSize $Db $Repo]
  puts $Html [ActivityByDev $Db]
  puts $Html [Tags $Db]
  #puts $Html [CheckinByDeveloper $Db]
  CheckinList $Html $Db
  puts $Html {<div class="w3-container w3-content"><br></div>}
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


proc main { argv } {

  set ArgIdx 0
  set ArgMax [llength $argv]
  array set Args [list]
  set Args(module) ""
  set Args(branch) "HEAD"
  set Args(cvsroot) $::cvs::Data(CVSROOT)
  set Args(output) "buildhtmlreport"
  set Args(ignore) ""
  set Args(commentfilter) ""

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
    } elseif { [string match "-only=*" $Argument] } {

      set Args(only) [lindex [split $Argument "="] 1]
    }
  }
  set cvs::Data(CVSROOT) $Args(cvsroot)

  #parray Args
  #parray cvs::Data

  try {
    file delete -force [cvs::GetDbFile $Args(module)]
  } on error {results options } {
    puts "ERROR file delete $results"
  }

  cvscl::changelog $Args(module) $Args(branch) commentfilter
}

#puts $argv0
#puts $argv

main $argv
