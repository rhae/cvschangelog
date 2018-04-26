#!/bin/tclsh

lappend auto_path sqlite3
package require sqlite3

source libs/gp.tcl

proc _ReadEnv { Var Default } {
  if { $Var ni [array names ::env] } {
    return $Default
  }
  return $::env($Var)
}

namespace eval cvs {

  variable Data
  

  set Data(CVS) [_ReadEnv CVS cvs]
  set Data(CVSROOT) [_ReadEnv CVSROOT ""]
  set Data(EDITOR) [_ReadEnv EDITOR vi]
}

proc cvs::rlog { Repo File } {
  variable Data

  file copy -force cvschangelogbuilder.2204609-A.10092.tmp $File
  puts "copy cvschanlogbuilder... $File"
  return 0


  if { $Data(CVSROOT) eq "" } {
    puts "No CVSROOT specified! Please use the '-d' option"
    return -1
  }

  try {
    exec $Data(CVS) rlog $Repo > $File
  } trap CHILDSTATUS {results options } {
    puts "ERROR: $results"
  } on error {results options } {

  }

  return 0
}

proc cvs::InitDB { db } {
  $db eval {
    CREATE TABLE commits (
      commitid text,
      author text,
      date text,
      file text,
      revision text,
      branches text,
      lines text,
      comment text
    );

    CREATE TABLE tags (
      commitid text,
      tag text,
      date text,
      file text,
      revision text
    );
  }
}

proc cvs::InsertCommit { db File Checkin } {

  # puts [info level 0]

  set commitid [dict get $Checkin commitid]
  set author [dict get $Checkin author]
  set date [dict get $Checkin date]
  set revision [dict get $Checkin revision]
  set lines [dict get $Checkin lines]
  set comment [dict get $Checkin comment]

  $db eval {
    INSERT INTO commits(
      file,
      commitid,
      author,
      date,
      revision,
      lines,
      comment
    ) VALUES (
      $File,
      $commitid,
      $author,
      $date,
      $revision,
      $lines,
      $comment
    );
  }
}

proc cvs::InsertTag { db File Checkin } {

  set commitid [dict get $Checkin commitid]
  set author [dict get $Checkin author]
  set tag [dict get $Checkin tag]
  set date [dict get $Checkin date]
  set revision [dict get $Checkin revision]

  if { $tag eq "" } {
    puts "No Tag for: $File $revision $date"
    return;
  }

  $db eval {
    INSERT INTO tags(
      commitid,
      tag,
      date,
      file,
      revision
    ) VALUES (
      $commitid,
      $tag,
      $date,
      $File,
      $revision
    );
  }
}

proc cvs::GetTagsByDate { db MapVar } {
  upvar $MapVar Map

  $db eval {
    SELECT date, tag 
      FROM tags T 
      WHERE date = (
        SELECT MAX(date) 
        FROM tags 
        WHERE date = T.date AND tag = T.tag
      )
      GROUP BY tag
      ORDER BY date ASC;
  } {
    set Map($date) $tag
  }
}

proc cvs::rlog2sql { Repo commentfilter } {
  variable Data

  puts [info level 0]
  set RlogFile [file join /tmp ${Repo}.rlog]
  set Ret [rlog $Repo $RlogFile]
  if { $Ret < 0 } {
    return $Ret
  }

  set fd [open $RlogFile]
  set db cvsdb
  sqlite3 cvsdb /tmp/2204609.sqlite3

  InitDB $db

  set LineNo 0
  set History [dict create]
  set CVSTags [list]
  set RCSfile ""
  set CVSROOT_len [string length $Data(CVSROOT)]
  while {[gets $fd Line] >= 0} {
    incr LineNo
    switch -glob $Line {
      "RCS file:*" {
        set RCSfile [string range $Line 11+$CVSROOT_len end-2]
        dict set History file $RCSfile
        # puts "== $RCSfile"
      }
      "head:*" -
      "branch:*" -
      "locks:*" -
      "access list:*" {
      }
      "symbolic names:*" {
        set CVSTags [list]
        while {[gets $fd Line] >= 0} {
          incr LineNo
          lassign [split $Line ":"] Tag Version
          lappend CVSTags [list [string trim $Tag] [string trim $Version]]
          if { [string match "*keyword*" $Line] } {
            break;
          }
        }
        #puts $CVSTags
        dict set History tags $CVSTags
      }
      "total rev*" {
      }
      "description:*" {
        gets $fd Line
        incr LineNo
        set Checkin [dict create]
        set Comment ""
        set Cnt 1
        
        while {[gets $fd Line] >= 0} {
          incr LineNo
          switch -glob $Line {
            "revision*" {
              set Rev [lindex [split $Line] 1]
              dict set Checkin revision $Rev

              # CVS-Tag für die Revision suchen
              dict set Checkin tag ""
              foreach Item $CVSTags {
                lassign $Item TagName TagRev
                if { $Rev eq $TagRev } {
                  dict set Checkin tag $TagName
                }
              }
              #puts "Rev1 $Rev"
              #puts "Rev2 [dict get $Checkin tag]"
            }
            "date:*" {
              foreach Item [split $Line ";"] {
                set key [string range $Item 0 [string first ":" $Item]-1]
                switch $key {
                  "date" {
                    set Date [clock scan [string range $Item [string first ":" $Item]+1 end] -format {%Y/%m/%d %H:%M:%S}]
                    set value [clock format $Date -format {%Y-%m-%d %H:%M:%S}]
                  }
                  default {
                    set value [string range $Item [string first ":" $Item]+1 end]
                  }
                }
                if { $key ne "" } {
                  dict set Checkin [string trim $key] [string trim $value]
                }
              }
              if { ![dict exists $Checkin lines] } {
                try {
                  set Size [file size $RCSfile]
                  dict set Checkin lines "+$Size -0"
                } on error {results options} {
                  dict set Checkin lines "+10 -0"
                }
              }
            }
            "branches:*" {
            }
            "------------*" -
            "============*" {
              if { $commentfilter ne "" } {
                try {
                  set comment [{*}$commentfilter $Comment]
                } on error {results options} {
                  puts $results
                  puts $options
                  exit 1
                }
              }
              dict set Checkin comment [string trim $comment " \r\n\t"]
              InsertCommit $db $RCSfile $Checkin
              InsertTag    $db $RCSfile $Checkin
              set Comment ""
              set Checkin [dict create]

              if { [string match "===*" $Line] } {
                set History [dict create]
                break
              }
            }
            "*" {
              append Comment $Line "<br>"
            }
          }
        }
      }
    }
  }
  close $fd

  puts "Lines read: $LineNo"
  return 0
}

proc cvs::ReadFile { Filename } {
  set fd [open $Filename]
  set Lines [read $fd]
  close $fd
  return $Lines
}

proc cvs::ChartCodeSize { Db } {

  set fd [open codesize.csv w+]
  set Size 0
  $Db eval {
    SELECT date, lines FROM commits ORDER BY strftime('%s', date) ASC;
  } {
    lassign [split $lines " "] added removed
    set Size [expr $Size + $added + $removed]

    puts $fd [format {%s;%s} $date $Size]
  }
  close $fd

  gp set terminal pngcairo font \"Helvetica,10\" size 600,300 enhanced
  gp set output "'codesize.png'"
  gp set datafile separator "';'"
  gp set style line 101 lc rgb "'#808080'" lt 1 lw 1
  gp set border 3 front ls 101
  gp set tics nomirror out scale 0.75

  gp set style line 1 lw 2 lc rgb '#0099ff'

  gp set style data steps
  gp set timefmt "'%Y-%m-%d %H:%M:%S'"
  gp set yrange \[ 0 : \]
  gp set xdata time
  gp unset key

  gp set format x "\"%d.%b\\n%Y\""
  gp set grid
  gp plot "'codesize.csv' " using 1:2 ls 1
  gp exit
  
}

proc cvs::RepoInfo { Db } {

  return {
    <div class="w3-container w3-content">
        <div class="w3-panel w3-x-blue-st">
          <p>CVS-Repository</p>
        </div>
  
        <table class="w3-table-all w3-small">
            <tr>
                <td>Erstellt</td>
                <td>2018-21-04 12:25</td>
            </tr>
            <tr>
              <td>Repository</td>
              <td>2204609</td>
            </tr>
            <tr>
                <td>CVSROOT</td>
                <td>ext:hsdghjg</td>
            </tr>
            <tr>
                <td>Branch</td>
                <td>HEAD</td>
            </tr>
        </table>
      </div>
  }
}

proc cvs::CodeSize { Db } {

  set FNCodeSize [ChartCodeSize $Db]

  return {
    <div class="w3-container w3-content">
      <div class="w3-panel w3-x-blue-st">
        <p>Codegr&ouml;&szlig;e</p>
      </div>

      <div class="w3-container">
          <img src="codesize.png" class="w3-x-img-center">
      </div>
    </div>
  }
}

proc cvs::CheckinByDeveloper { Db } {

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

proc cvs::CheckinList { fd Db } {

  puts $fd {<div class="w3-container w3-content">
        <div class="w3-panel w3-x-blue-st">
          <p>Checkins</p>
        </div>
        <input class="w3-input w3-border w3-padding" type="text" placeholder="Search in checkins.." id="myInput" onkeyup="myFunction()">
        <br>
        <table class="w3-table-narrow-all w3-tiny" id="myTable">
          <col style="width:8%">
          <col style="width:5%">
          <col style="width:12%">
          <col style="width:30%">
          <col style="width:45%">
        <tr class="w3-dark-grey">
          <th>Datum</th>
          <th>Autor</th>
          <th>Tag</th>
          <th>Dateien</th>
          <th>Kommentar</th>
        </tr>
  }

  array set DateTagMap [list]
  GetTagsByDate $Db DateTagMap
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
        set Tag [format {<div class="w3-tag w3-black">%s</div>} $DateTagMap($FullDate)]
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

      if { $date eq $LastDate } {
        set date ""
      }
      set LastDate $date

      set Tag ""
      if { $FullDate in [array names DateTagMap] } {
        set Tag [format {<div class="w3-tag w3-black">%s</div>} $DateTagMap($FullDate)]
      }
      set CheckIn [format {        <tr>
          <td>%s</td>
          <td>%s</td>
          <td>%s</td>
          <td>} $date $author $Tag]

      set LastComment $comment
      set LastCommit $commitid
      unset Files
      set Files [list]
    }

    set f [string range $file 14 end]
    lappend Files [list $f $revision $lines]
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
  return

  puts $fd {
      <div class="w3-container w3-content">
        <div class="w3-panel w3-x-blue-st">
          <p>Checkins</p>
        </div>

        <table class="w3-table-narrow-all w3-tiny">
          <col style="width:12%">
          <col style="width:8%">
          <col style="width:15%">
          <col style="width:20%">
          <col style="width:45%">

          <tr class="w3-dark-grey">
            <th>Datum</th>
            <th>Autor</th>
            <th>Tag</th>
            <th>Dateien</th>
            <th>Kommentar</th>
          </tr>
          <tr>
            <td>21.04.2018 06:18</td>
            <td>hae</td>
            <td><div class="w3-tag w3-red">T110-40-201_RC01</div></td>
            <td>
              README 1.2, +3 -0<br>
              src/main.c 1.2, +144 -12<br>
            </td>
            <td>
              Merge A11111_Feature_01
            </td>
          </tr>
        </table>
      </div>
  }
}

proc cvs::Tags { Db } {
  array set DateTagMap [list]
  GetTagsByDate $Db DateTagMap
  
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
  
  foreach {FullDate Tag} [lsort -stride 2 -index 0 -decreasing [array get DateTagMap]] {
    lassign [split $FullDate " "] Date
    append Html [format {<tr><td>%s</td><td>%s</td></tr>} $Tag $Date] "\n"
  }
  append Html {</table>
    </div>}
}

proc cvs::changelog { Repo commentfilter } {

  set Ret [rlog2sql $Repo $commentfilter]
  if { $Ret < 0 } {
    return $Ret
  }

  set Db cvsdb
  sqlite3 $Db /tmp/2204609.sqlite3

  set Css [ReadFile w3c.css]
  append Css {.w3-x-img-center{display:block;margin-left: auto; margin-right:auto}} "\n"
  append Css {.w3-x-blue-st{color:#fff!important;background-color: #009ce2}} "\n"

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
  puts $Html [RepoInfo $Db]
  puts $Html [CodeSize $Db]
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
  set Args(branch) ""
  set Args(cvsroot) ""
  set Args(ignore) ""
  set Args(commentfilter) ""

  while { $ArgIdx < $ArgMax } {
    
    set Argument [lindex $argv $ArgIdx]
    incr ArgIdx
    if { [string match "-m=*" $Argument] || [string match "-module=*" $Argument] } {
      set Args(module) [lindex [split $Argument "="] 1]
    } else if { [string match "-branch=*" $Argument] } {
      set Args(branch) [lindex [split $Argument "="] 1]
    }
  }
  parray Args

  catch {
    file delete -force /tmp/2204609.sqlite3
  }

  set Repo 2204609

  cvs::changelog $Repo commentfilter
}

#puts $argv0
#puts $argv

main $argv