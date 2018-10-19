
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

proc cvs::get { Repo option } {
  variable Data

  switch $option {
    -dir {
      return [file join $Data(TEMP) cvscl_$Repo]
    }
    default {
      error "unknown option $option."
    }
  }
}

proc cvs::checkout { Repo } {
  variable Data

  set Dir [get $Repo -dir]

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

proc ::cvs::update { Db Dir Rev} {
  variable Data

  puts [info level 0]
  set OldDir [pwd]
  file mkdir $Dir
  cd $Dir

  set Cnt 10
  set Files [list]
  foreach F [GetFiles $Db] {
    incr Cnt -1
    lappend Files $F

    if { $Cnt == 0 } {
      try {
        exec $Data(CVS) update -r $Rev {*}$Files
        set Found 0
        set Status 0
      } trap CHILDSTATUS {results options } {
        puts "CHILDSTATUS: $results"
      } on error {results options } {
        puts "ERROR: $results"
      }
      set Cnt 10
      set Files [list]
    }
  }

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
      state text,
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
  set state [dict get $Checkin state]
  set comment [dict get $Checkin comment]

  $db eval {
    INSERT INTO commits(
      file,
      commitid,
      author,
      date,
      revision,
      lines,
      state,
      comment
    ) VALUES (
      $File,
      $commitid,
      $author,
      $date,
      $revision,
      $lines,
      $state,
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
  set tags [dict get $Checkin tag]
  set date [dict get $Checkin date]
  set revision [dict get $Checkin revision]

  if { $tags eq "" } {
    # puts "No Tag for: $File $revision $date"
    return;
  }

  foreach tag $tags {
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
}

#
#
#
proc cvs::UpdateLineCnt { db File Version Cnt } {

  set Lines "+$Cnt +0"

  set Ret [$db eval {
    UPDATE commits
      SET lines = $Lines
    WHERE
      file == $File AND
      revision == $Version;
  }]
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
  set TagList [list]

  $db eval {
    SELECT DISTINCT tag FROM tags;
  } {
    lappend TagList $tag
  }

  foreach Tag $TagList {
    $db eval {
      SELECT MAX(date) AS date, tag
        FROM tags
        WHERE tag == $Tag
    } {
      lappend Map($date) $tag
    }
  }

  return
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
# returns all files in DB
proc cvs::GetFiles { db } {
  return [$db eval {
    SELECT DISTINCT file FROM commits;
  }]
}

#
# \param db     handle to database
# \param type   all or distinct file
#
# \return list with autor and number of modified files
proc cvs::GetFileCntModified { db type branch } {

  set rev ""
  if { $branch eq "HEAD" } {
    set rev "1.%"
  }

  if { $type eq "all" } {
    return [$db eval {
      SELECT author, COUNT(*) FROM commits WHERE revision like $rev GROUP BY author;
    }]
  }

  set Result [list]
  set Cnt 1
  set LastAuthor ""
  $db eval {
      SELECT DISTINCT author, file FROM commits WHERE revision like $rev ORDER BY author;
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

proc cvs::GetChangesByUser { db author timeframe branch } {
  set Result [list]

  set rev ""
  if { $branch eq "HEAD" } {
    set rev "1._"
  }

  $db eval {
    SELECT date, lines
      FROM commits
      WHERE author = $author AND revision like $rev
        AND date BETWEEN date( 'now', $timeframe ) AND date( 'now' )
  } {
    lappend Result $date $lines
  }
}

#
# import changes of CVS repository to SQLite db
#
# \param Repo           CVS Repository/module
# \param commentfilter  function name to filter texts from a commit comment
# \param OnlyDirFile    list of directories oder files. Can contain wildcards
#
proc cvs::rlog2sql { Repo commentfilter OnlyDirFile } {
  variable Data

  # puts [info level 0]
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
  set Start [clock seconds]

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

              # CVS-Tags für die Revision suchen
              dict set Checkin tag ""
              foreach Item $CVSTags {
                lassign $Item TagName TagRev
                if { $Rev eq $TagRev } {
                  dict lappend Checkin tag $TagName
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
                dict set Checkin lines "+0 -0"
              }
            }
            "branches:*" {
            }
            "----------------------------" -
            "============*" {
              if { $OnlyDirFile ne "" } {
                set InsertToDb 1
                foreach O $OnlyDirFile {
                  if { ![string match $O $RCSfile] } {
                    set InsertToDb 0
                  }
                }
                if { !$InsertToDb } {
                  # puts "File $RCSfile does not match -only argument"
                  break
                }
              }

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
  puts [format {  took %d s} [expr [clock seconds] - $Start]]
  return 0
}
