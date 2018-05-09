
lappend auto_path sqlite3
package require sqlite3

proc _ReadEnv { Var Default } {
  if { $Var ni [array names ::env] } {
    return $Default
  }
  return $::env($Var)
}

namespace eval cvs {

  variable Data
  
  #parray ::env

  set Data(CVS) [_ReadEnv CVS cvs]
  set Data(CVSROOT) [_ReadEnv CVSROOT ""]
  set Data(EDITOR) [_ReadEnv EDITOR vi]
  set Data(TEMP) [_ReadEnv TEMP ""]
  if { $Data(TEMP) eq "" } {
    set Data(TEMP) [_ReadEnv TMPDIR "/tmp"]
  }
}

#
#  Generate rlogfile from repository
#
#  \param Repo    CVS Repository
#  \param File    Filename for rlog-file
#
#  \return 0 when successfull
#
proc cvs::rlog { Repo File } {
  variable Data

  if { [string match linux* [platform::identify]] } {
    file copy -force cvschangelogbuilder.2204609-A.10092.tmp $File
    puts "copy cvschanlogbuilder... $File"
    return 0
  }


  if { $Data(CVSROOT) eq "" } {
    puts "No CVSROOT specified! Please use the '-d' option"
    return -1
  }

  try {
    exec $Data(CVS) -d $Data(CVSROOT) rlog $Repo > $File
  } trap CHILDSTATUS {results options } {
    puts "ERROR: $results"
  } on error {results options } {
  }

  return 0
}


proc cvs::checkout { Repo } {
  variable Data

  set Dir [file join $Data(TEMP) cvscl_$Repo]

  file delete -force $Dir
  set Status -1
  set Start [clock seconds]
  puts "Checkout $Repo"
  try {
    exec $Data(CVS) -d $Data(CVSROOT) checkout -d $Dir $Repo
    set Status 0
  } trap CHILDSTATUS {results options } {
    puts "ERROR: $results"
  } on error {results options } {
    set Status 0
  }
  set Diff [expr [clock seconds] - $Start]
  puts [format {  took %d s} $Diff ]

  if { $Status < 0 } {
    return ""
  }

  return $Dir
}

proc ::cvs::_update {Dir Rev} {
  variable Data
  set OldDir [pwd]
  cd $Dir

  foreach _Dir [glob -nocomplain -types d *] {
    set Dir2 [file join $Dir $_Dir]
    _update $Dir2 $Rev
  }

  set Files [glob -nocomplain -types f *]
  if { $Files ne "" } {
    try {
      exec $Data(CVS) update -r $Rev {*}$Files
      set Status 0
    } trap CHILDSTATUS {results options } {
      puts "CHILDSTATUS: $results"
    } on error {results options } {
      # puts "ERROR: $results"
    }
  } else {
  }

  cd $OldDir
}

proc cvs::update { Dir Rev } {
  variable Data

  set OldDir [pwd]

  set Start [clock seconds]
  puts "Update $Dir $Rev"

  _update $Dir $Rev

  set Diff [expr [clock seconds] - $Start]
  puts [format {  took %d s} $Diff ]

  cd $OldDir
}

#
#  Get sqlite db filename
#
#  \return db filename
#
proc cvs::GetDbFile { Repo } {
  variable Data

  return [file join $Data(TEMP) ${Repo}.sqlite3]
}


#
#  Initializes the sqlite db
#
#  Create the schema.
#
#  \param    db-handle which was created with sqlite3
#
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

#
#  Insert a commit into the db
#
#  The dictionary Checkin must contain the following keys
#    - commitid
#    - author
#    - date
#    - revision
#    - lines
#    - comment
#
#  \param  db      db-handle
#  \param  File    RCS-File
#  \param  Checkin a tcl dictionary with the contents
#
#
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

#
#  Insert a tag into the db
#
#  The dictionary Checkin must contain the following keys
#    - commitid
#    - author
#    - date
#    - revision
#    - tag
#
#  \param  db      db-handle
#  \param  File    RCS-File
#  \param  Checkin a tcl dictionary with the contents
#
#
proc cvs::InsertTag { db File Checkin } {

  set commitid [dict get $Checkin commitid]
  set author [dict get $Checkin author]
  set tag [dict get $Checkin tag]
  set date [dict get $Checkin date]
  set revision [dict get $Checkin revision]

  if { $tag eq "" } {
    # puts "No Tag for: $File $revision $date"
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

#
#  Queries the db and fills the variable MapVar
#
#  MapVar is treated as array. The keys are dates. The values are the tag name.
#
#  \param   db      db-handle
#  \param   MapVar  variable name (like c pointer) to store the result
#
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

#
# \return list of files in this repository
proc cvs::GetTotalFiles { db } {
  return [$db eval {
    SELECT DISTINCT COUNT(DISTINCT file) FROM commits;
  }]
}

#
# returns list of authors sorted by author
proc cvs::GetAuthors { db } {
  return [$db eval {
    SELECT DISTINCT author FROM commits ORDER BY author ASC;
  }]
}

#
# \param db     handle to database
# \param type   all or distinct file
#
# \return list with autor and number of modified files
proc cvs::GetFileCntModified { db type } {

  if { $type eq "all" } {
    return [$db eval {
      SELECT author, COUNT(*) FROM commits GROUP BY author;
    }]
  }

  set Result [list]
  set Cnt 1
  set LastAuthor ""
  $db eval {
      SELECT DISTINCT author, file FROM commits ORDER BY author;
  } {
    if { $author eq $LastAuthor } {
      #set LastAuthor $author
      incr Cnt
    } elseif { $author ne $LastAuthor } {
      if { $LastAuthor ne "" } {
        lappend Result $LastAuthor $Cnt
      }
      set Cnt 1
      set LastAuthor $author
    }
  }
  lappend Result $LastAuthor $Cnt
  puts $Result

  return $Result
}

#
# \return list with author and last commit date
proc cvs::GetLastCommit { db } {
  return [$db eval {
    SELECT author, MAX(date) FROM commits GROUP BY author;
  }]
}

#
#
# \return list with weekday and sum of commits on that day
proc cvs::GetCommitsByWeekday { db } {
  set Weekdays [list So Mo Di Mi Do Fr Sa]
  set Result [list]
  $db eval {
    SELECT wday, COUNT(wday) AS cnt
      FROM (
        SELECT strftime( '%w', date ) AS wday
        FROM commits 
        ORDER BY wday
      )
      GROUP BY wday;
  } {
    set Weekday [lindex $Weekdays $wday]
    lappend Result $Weekday $cnt
  }
  return $Result
}

#
#
# \return list with hour and sum of commits on that day
proc cvs::GetCommitsByHour { db } {
  set Result [list]
  $db eval {
    SELECT hour, COUNT(hour) AS cnt
      FROM (
        SELECT strftime( '%H', date ) AS hour
        FROM commits
        ORDER BY hour
      )
      GROUP BY hour;
  } {
    lappend Result $hour $cnt
  }
  return $Result
}

#
# import changes of CVS repository to SQLite db
#
# \param Repo           CVS Repository/module
# \param commentfilter  function name to filter texts from a commit comment
#
proc cvs::rlog2sql { Repo commentfilter } {
  variable Data

  puts [info level 0]
  set RlogFile [file join $Data(TEMP) ${Repo}.rlog]
  set Ret [rlog $Repo $RlogFile]
  if { $Ret < 0 } {
    return $Ret
  }

  set fd [open $RlogFile]
  set db cvsdb
  set Filename [GetDbFile $Repo]
  puts "Create SQLite3 db: '$Filename'"
  sqlite3 cvsdb $Filename

  InitDB $db

  set LineNo 0
  set History [dict create]
  set CVSTags [list]
  set RCSfile ""
  set RepoLen [string length $Repo]
  set Encoding [encoding system]

  while {[gets $fd Line] >= 0} {
    incr LineNo
    switch -glob $Line {
      "RCS file:*" {
        set Idx [string first $Repo $Line]
        incr Idx $RepoLen
        set RCSfile [string range $Line $Idx+1 end-2]
        dict set History file $RCSfile

        #puts "== $Line"
        #puts "xx   $RCSfile       $Idx     $Repo"
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
                set key   [string trim [string range $Item 0 [string first ":" $Item]-1]]
                set value [string trim [string range $Item [string first ":" $Item]+1 end]]
                switch $key {
                  "date" {
                    set Date [clock scan $value -format {%Y/%m/%d %H:%M:%S}]
                    set value [clock format $Date -format {%Y-%m-%d %H:%M:%S}]
                  }
                  "author" {
                    if { [string index $value 0] eq "\\" } {
                      set value [string range $value 1 end]
                    }
                    set value [string totitle $value]
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
            "----------------------------" -
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
              dict set Checkin comment [encoding convertto utf-8 [string trim $comment " \r\n\t"]]
              try {
                  InsertCommit $db $RCSfile $Checkin
                  InsertTag    $db $RCSfile $Checkin
              } on error { result options } {
                  puts [format {Line %5d, %s%s  %s} $LineNo $RCSfile "\n" $result]
                  foreach k [dict keys $Checkin] {
                      puts [format {%15s = %s} $k [dict get $Checkin $k]]
                  }
                  exit 1
              }
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
