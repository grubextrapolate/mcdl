#!/usr/bin/perl -w
#
# mcdl - Quickly add CD info to MySQL backend using CDDB 
# Copyright (C) 1999-2000 Robert S. Dubinski, dubinski@mscs.mu.edu
# additional modifications since v0.1.0 Copyright (C) 2003-2004 by Russ 
# Burdick, grub@extrapolation.net
# Fixes and functionality additions by contributors in CHANGES file.
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.
#

use strict;
use diagnostics;

use lib qw(/path/to/dir/with/CDDB_get2);
use CDDB_get2 qw( get_cddb get_discids );
use DBI;
use Env;
use Getopt::Long;

### BEGIN VARIABLE DEFINITIONS
my (
      $VERSION,             # mcdl version number.  
      $print_help_opt,      # getopt print_help argument variable
      $version_opt,         # getopt version argument variable
      $report_opt,          # getopt report argument variable
      $create_tables_opt,   # getopt maketables argument variable
      $drop_tables_opt,     # getopt droptables argument variable
      $dbuser,              # getopt username variable replacement
      $dbpass,              # getopt password variable replacement
      $dbhost,              # getopt database hostname replacement
      $dbname,              # getopt database name replacement
      $cddev,               # getopt cd device name replacement
      $quiet,               # if true, don't ask permission to add to database
      $cddb_dir,            # Local CDDB directory
      $cddb_mode,           # mode to contact CDDB server
      $cddb_host,           # CDDB host to query for cd info
      $cddb_port,           # CDDB port to connect to
      %cd,                  # info on the current disc
      $dbh                  # DBI database handle
);
#### END VARIABLE DEFINITIONS

## Fill these in to simplify your command line.
$dbuser = "YOUR_DB_USER";
$dbpass = "YOUR_DB_PASS";
$dbhost = "YOUR_DB_HOSTNAME_OR_IP"; 
$dbname = "YOUR_DB_NAME"; 
$cddev = "/dev/cdrom";
$cddb_dir = "$ENV{'HOME'}/.cddb";
$cddb_mode = "http";
$cddb_host = "us.freedb.org";
$cddb_port = 8880;

# Please don't change this when sending patches.
$VERSION="0.4.0 (25 Feb 2004)";                

# Remove buffering
$| = 1;

my $opt = GetOptions(
   "version"         => \$version_opt,
   "help"            => \$print_help_opt,
   "report"          => \$report_opt,
   "create_tables"   => \$create_tables_opt,
   "drop_tables"     => \$drop_tables_opt,
   "dbuser=s"        => \$dbuser,
   "dbpass=s"        => \$dbpass,
   "dbhost=s"        => \$dbhost,
   "dbname=s"        => \$dbname,
   "device=s"        => \$cddev,
   "cddbdir=s"       => \$cddb_dir,
   "cddbmode=s"      => \$cddb_mode,
   "cddbhost=s"      => \$cddb_host,
   "cddbport=i"      => \$cddb_port,
   "quiet"           => \$quiet
);

if ($print_help_opt || !$opt) {
   print_help();
   exit;
}

if ($version_opt) {
   print "Version $VERSION\n";
   exit;
}

if ($report_opt) {
   connect_db();
   display_report();
   disconnect_db();
   exit;
}

if ($create_tables_opt) {
   connect_db();
   create_tables();
   disconnect_db();
   exit;
}

if ($drop_tables_opt) {
   connect_db();
   drop_tables();
   disconnect_db();
   exit;
}

connect_db();
normal_run();
disconnect_db();
exit;

my $normal_run;
sub normal_run {
   my $user_input = "y";
   while (lc($user_input) ne "n") {
      disc_cycle();
      print "\nTry another disc? ([y]/n) ";
      $user_input = <STDIN>;
      chomp ($user_input);
   }
   print "Thanks for trying this software.\n";
   exit;
}

my $disc_cycle;
sub disc_cycle {
   print "\n";
   print "---Insert CD into drive and press a key to begin---\n";
   print "\n";
   my $user_input = <STDIN>;  # FIXME: find cleaner way to get a key
   print "getting CD info...\n";
   if (get_disc_info()) {
      ask_to_add();
   }
}

my $get_disc_info;
sub get_disc_info {
   my $ret = 0;
   my %config;
   my $cdh;

   $cd{artist} = undef;
   $cd{title} = undef;
   $cd{cat} = "unknown";
   $cd{id} = 0;
   $cd{tno} = 0;
   $cd{year} = "";
   @{$cd{track}} = ();

   # Try to find CD in $HOME/.cddb
   if ( -d "$cddb_dir" ) {
      print "Using data found in $cddb_dir\n";
      $cdh = read_local_cddb();
   } else {
      $config{input} = 1;
      $config{CD_DEVICE} = $cddev;
      $config{CDDB_MODE} = "http";
      $config{CDDB_HOST} = "us.freedb.org";
      $config{CDDB_PORT} = 8880;
      $cdh = get_cddb(\%config);
   }

   if ($cdh && $cdh->{title}) {
      %cd = %{$cdh};
      $ret = 1;
   } else {
      my ($id2, $tot, $toc);
      my $diskid=get_discids();
      $id2=$diskid->[0];
      $tot=$diskid->[1];
      $toc=$diskid->[2];
      my $id = sprintf("%08x", $id2); 

      print "no cddb entry found for $id\n";
      $ret = 0;
   }

   return $ret;
}

my $ask_to_add;
sub ask_to_add {
   my $user_input = "z";

   if ($quiet) {
      print_report(\%cd);
      save_disc_info(\%cd);
   } else {
      while (lc($user_input) ne "y") {
         print_report(\%cd);
         print "ok to save? ([y]/n/e) ";

         $user_input = <STDIN>;
         chomp($user_input);
         if (lc($user_input) eq 'n') {
            warn "Aborting per user request...\n";
            return;
         } elsif (lc($user_input) eq 'e') {
            edit_cd_info(\%cd);
         } else {
            $user_input = "y";
            save_disc_info(\%cd);
         }
      }
   }
}

my $save_disc_info;
sub save_disc_info {
   my $cd = shift;
   my $db_artistid = 0;
   my $db_catid = 0;
   my $db_cdid = 0;

   $db_artistid = get_artist_id($cd->{artist});
   if ($db_artistid) {
      print "Already seen artist $cd->{artist}...artist not ok to ";
      print "add to the Artist table\n";
   } else {
      print "artist $cd->{artist} ok to add to Artist table\n";
      $db_artistid = insert_artist($cd->{artist});
   }

   $db_catid = get_cat_id($cd->{cat});
   if ($db_catid) {
      print "Already seen cat $cd->{cat}...  not ok to add to ";
      print "Genre table\n";
   } else {
      print "cat $cd->{cat} ok to add to Genre table\n";
      $db_catid = insert_cat($cd->{cat});
   }

   $db_cdid = get_cd_id($cd->{id}, $db_artistid);
   if ($db_cdid) {
      print "Already seen cd $cd->{id} ($cd->{title}). cd not ok ";
      print "to add to CD table\n";
   } else {
      print "cd $cd->{id} ($cd->{title}) ok to add to CD table\n";
      $db_cdid = insert_cd($cd, $db_artistid, $db_catid);

      foreach my $track (@{$cd->{track}}) {
         print "track $track added to Song table\n";
         insert_song($track, $db_cdid);
      }
   }
}

my $get_artist_id;
sub get_artist_id {
   my $testartist = shift;
   my $ret = 0;

   my $sql = qq(SELECT ARTIST_ID FROM Artist );
   $sql .= qq(WHERE ARTIST_NAME = ) . $dbh->quote($testartist);

   my $sth = $dbh->prepare($sql);
   die "DBI error with prepare:", $sth->errstr unless $sth;

   my $result = $sth->execute;
   die "DBI error with execute:", $sth->errstr unless $result;

   if ($result) {
      my $row = $sth->fetchrow_hashref;
      $ret = $row->{ARTIST_ID};
   }

   # Finish that database call
   $sth->finish;

   return $ret;
}

my $insert_artist;
sub insert_artist {
   my $ret = 0;
   my $testartist = shift;

   my $sql = qq(INSERT INTO Artist SET );
   $sql .= qq(ARTIST_NAME = ) . $dbh->quote($testartist);

   my $sth = $dbh->prepare($sql);
   die "DBI error with prepare:", $sth->errstr unless $sth;

   my $result = $sth->execute;
   die "DBI error with execute:", $sth->errstr unless $result;

   # Finish that database call
   $sth->finish;

   $sql = qq(SELECT ARTIST_ID FROM Artist );
   $sql .= qq(WHERE ARTIST_NAME = ) . $dbh->quote($testartist);

   $sth = $dbh->prepare($sql);
   die "DBI error with prepare:", $sth->errstr unless $sth;

   $result = $sth->execute;
   die "DBI error with execute:", $sth->errstr unless $result;

   if ($result) {
      my $row = $sth->fetchrow_hashref;
      $ret = $row->{ARTIST_ID};
   }

   # Finish that database call
   $sth->finish;

   return $ret;
}

my $get_cat_id;
sub get_cat_id {
   my $testcat = shift;
   my $ret = 0;

   my $sql = qq(SELECT GENRE_ID FROM Genre );
   $sql .= qq(WHERE GENRE_NAME = ) . $dbh->quote($testcat);

   my $sth = $dbh->prepare($sql);
   die "DBI error with prepare:", $sth->errstr unless $sth;

   my $result = $sth->execute;
   die "DBI error with execute:", $sth->errstr unless $result;

   if ($sth->rows) {
      my $row = $sth->fetchrow_hashref;
      $ret = $row->{GENRE_ID};
   }

   return $ret;
}

my $insert_cat;
sub insert_cat {
   my $ret = 0;
   my $testcat = shift;

   my $sql = qq(INSERT INTO Genre SET );
   $sql .= qq(GENRE_NAME = ) . $dbh->quote($testcat);

   my $sth = $dbh->prepare($sql);
   die "DBI error with prepare:", $sth->errstr unless $sth;

   my $result = $sth->execute;
   die "DBI error with execute:", $sth->errstr unless $result;

   # Finish that database call
   $sth->finish;

   $sql = qq(SELECT GENRE_ID FROM Genre );
   $sql .= qq(WHERE GENRE_NAME = ) . $dbh->quote($testcat);

   $sth = $dbh->prepare($sql);
   die "DBI error with prepare:", $sth->errstr unless $sth;

   $result = $sth->execute;
   die "DBI error with execute:", $sth->errstr unless $result;

   if ($sth->rows) {
      my $row = $sth->fetchrow_hashref;
      $ret = $row->{GENRE_ID};
   }

   return $ret;
}

my $get_cd_id;
sub get_cd_id {
   my $id = shift;
   my $artistid = shift;
   my $ret = 0;

   my $sql = qq(SELECT CD_ID FROM CD );
   $sql .= qq(WHERE CDDB_ID = ) . $dbh->quote($id);
   $sql .= qq( AND ARTIST_ID = ) . $dbh->quote($artistid);

   my $sth = $dbh->prepare($sql);
   die "DBI error with prepare:", $sth->errstr unless $sth;

   my $result = $sth->execute;
   die "DBI error with execute:", $sth->errstr unless $result;

   if ($result) {
      my $row = $sth->fetchrow_hashref;
      $ret = $row->{CD_ID};
   }

   # Finish that database call
   $sth->finish;

   return $ret;
}

my $insert_cd;
sub insert_cd {
   my $cd = shift;
   my $artid = shift;
   my $catid = shift;
   my $ret = 0;

   my $sql = qq(INSERT INTO CD SET );
   $sql .= qq(CD_TITLE = ) . $dbh->quote($cd->{title});
   $sql .= qq(, CD_YEAR = ) . $dbh->quote($cd->{year});
   $sql .= qq(, CDDB_ID = ) . $dbh->quote($cd->{id});
   $sql .= qq(, ARTIST_ID = ) . $dbh->quote($artid);
   $sql .= qq(, GENRE_ID = ) . $dbh->quote($catid);

   my $sth = $dbh->prepare($sql);
   die "DBI error with prepare:", $sth->errstr unless $sth;

   my $result = $sth->execute;
   die "DBI error with execute:", $sth->errstr unless $result;

   # Finish that database call
   $sth->finish;

   $sql = qq(SELECT CD_ID FROM CD );
   $sql .= qq(WHERE CDDB_ID = ) . $dbh->quote($cd->{id});
   $sql .= qq( AND ARTIST_ID = ) . $dbh->quote($artid);

   $sth = $dbh->prepare($sql);
   die "DBI error with prepare:", $sth->errstr unless $sth;

   $result = $sth->execute;
   die "DBI error with execute:", $sth->errstr unless $result;

   if ($result) {
      my $row = $sth->fetchrow_hashref;
      $ret = $row->{CD_ID};
   }

   # Finish that database call
   $sth->finish;

   return $ret;
}

my $insert_song;
sub insert_song {
   my $testtrack = shift;
   my $cdid = shift;

   my $sql = qq(INSERT INTO Song SET );
   $sql .= qq(CD_ID = ) . $dbh->quote($cdid);
   $sql .= qq(, SONG_NAME = ) . $dbh->quote($testtrack);

   my $sth = $dbh->prepare($sql);
   die "DBI error with prepare:", $sth->errstr unless $sth;

   my $result = $sth->execute;
   die "DBI error with execute:", $sth->errstr unless $result;

   # Finish that database call
   $sth->finish;
}

my $banner;
sub banner {
   print "\n";
   print "mcdl version $VERSION, Copyright (C) 1999-2000 Robert S. Dubinski\n";
   print "mcdl comes with ABSOLUTELY NO WARRANTY; for details\n";
   print "read `WARRANTY'.  This is free software, and you are welcome\n";
   print "to redistribute it under certain conditions; read `COPYING'\n"; 
   print "for details.\n";
   print "\n";
}

my $print_help;
sub print_help {
   print "\n";
   print "mcdl version $VERSION, Copyright (C) 1999-2000 Robert S. Dubinski\n";
   print "Simple program to rapidly add CD listings to a MySQL backend.\n";
   print "\n";
   print "Usage: mcdl \[OPTIONS\]...\n";
   print "\n";
   print "\n";
   print "--help                 print this help message\n";
   print "\n";
   print "--dbhost               set database host name\n";
   print "--dbname               set database name\n";
   print "--user                 set connecting username\n";
   print "--pass                 set connecting password\n";
   print "\n";
   print "--create_tables        create necessary table layout\n";
   print "--drop_tables          destroy necessary table layout\n";
   print "\n";
   print "--report               print out current CD list\n";
   print "\n";
   print "--version              output version information and exit\n";
   print "\n";
   print "--quiet                don't ask per disc confirmation to add\n";
   print "\n";
   exit(0);
}

my $create_tables;
sub create_tables {
   my $sql = qq{CREATE TABLE Artist (};
   $sql .= qq{ARTIST_ID SMALLINT UNSIGNED PRIMARY KEY NOT NULL AUTO_INCREMENT, };
   $sql .= qq{ARTIST_NAME varchar(80))};

   my $sth = $dbh->prepare($sql);
   die "DBI error with prepare:", $sth->errstr unless $sth;

   my $result = $sth->execute;
   die "DBI error with execute:", $sth->errstr unless $result;

   # Finish that database call
   $sth->finish;

   $sql = qq{CREATE TABLE CD (};
   $sql .= qq{CD_ID SMALLINT UNSIGNED PRIMARY KEY NOT NULL AUTO_INCREMENT,};
   $sql .= qq{CD_TITLE VARCHAR(80),};
   $sql .= qq{CD_YEAR YEAR,};
   $sql .= qq{CDDB_ID CHAR(8),};
   $sql .= qq{ARTIST_ID SMALLINT UNSIGNED,};
   $sql .= qq{GENRE_ID SMALLINT UNSIGNED)};

   $sth = $dbh->prepare($sql);
   die "DBI error with prepare:", $sth->errstr unless $sth;

   $result = $sth->execute;
   die "DBI error with execute:", $sth->errstr unless $result;

   # Finish that database call
   $sth->finish;

   $sql = qq{CREATE TABLE Song (};
   $sql .= qq{SONG_ID MEDIUMINT UNSIGNED PRIMARY KEY NOT NULL AUTO_INCREMENT,};
   $sql .= qq{CD_ID SMALLINT UNSIGNED NOT NULL,};
   $sql .= qq{SONG_NAME VARCHAR(80))};

   $sth = $dbh->prepare($sql);
   die "DBI error with prepare:", $sth->errstr unless $sth;

   $result = $sth->execute;
   die "DBI error with execute:", $sth->errstr unless $result;

   # Finish that database call
   $sth->finish;

   $sql = qq{CREATE TABLE Genre (};
   $sql .= qq{GENRE_ID SMALLINT UNSIGNED PRIMARY KEY NOT NULL AUTO_INCREMENT,};
   $sql .= qq{GENRE_NAME VARCHAR(80) NOT NULL DEFAULT 'unknown')};

   $sth = $dbh->prepare($sql);
   die "DBI error with prepare:", $sth->errstr unless $sth;

   $result = $sth->execute;
   die "DBI error with execute:", $sth->errstr unless $result;

   # Finish that database call
   $sth->finish;

   print "tables created.\n";
   exit;
}

my $drop_tables;
sub drop_tables {
   my $sql = qq(DROP TABLE Artist);

   my $sth = $dbh->prepare($sql);
   die "DBI error with prepare:", $sth->errstr unless $sth;

   my $result = $sth->execute;
   die "DBI error with execute:", $sth->errstr unless $result;

   # Finish that database call
   $sth->finish;

   $sql = qq(DROP TABLE CD);

   $sth = $dbh->prepare($sql);
   die "DBI error with prepare:", $sth->errstr unless $sth;

   $result = $sth->execute;
   die "DBI error with execute:", $sth->errstr unless $result;

   # Finish that database call
   $sth->finish;

   $sql = qq(DROP TABLE Song);

   $sth = $dbh->prepare($sql);
   die "DBI error with prepare:", $sth->errstr unless $sth;

   $result = $sth->execute;
   die "DBI error with execute:", $sth->errstr unless $result;

   # Finish that database call
   $sth->finish;

   $sql = qq(DROP TABLE Genre);

   $sth = $dbh->prepare($sql);
   die "DBI error with prepare:", $sth->errstr unless $sth;

   $result = $sth->execute;
   die "DBI error with execute:", $sth->errstr unless $result;

   # Finish that database call
   $sth->finish;

   print "tables deleted.\n";

   exit;
}

my $read_local_cddb;
sub read_local_cddb {
   my $cd;

   my ($id2, $tot, $toc);
   my $diskid=get_discids();
   $id2=$diskid->[0];
   $tot=$diskid->[1];
   $toc=$diskid->[2];
   my $id = sprintf("%08x", $id2); 
   $cd->{id} = $id;

   $cd->{artist} = undef;
   $cd->{title} = undef;
   $cd->{cat} = "unknown";
   $cd->{tno} = 0;
   $cd->{year} = "";
   @{$cd->{track}} = ();

   if (open (DATA, "$cddb_dir/$cd->{id}")) {

      while (<DATA>) {
         if ( m,^DTITLE=(.*) / (.*)$, ) {
            $cd->{artist} = $1;
            $cd->{title} = $2;
         }

         if ( m/^DGENRE=(.*)$/ or m/^210 (.*) $cd->{id}/ ) {
            $cd->{cat} = $1;
         }

         if ( m/^DYEAR=([0-9]*)$/ ) {
            $cd->{year} = $1;
         }

         if ( m/^TTITLE[0-9]*=(.*)$/ ) {
            ${$cd->{track}}[$cd->{tno}] = $1;
            $cd->{tno}++;
         }
      }
      close (DATA);

   } else {
      warn "Can't open $cddb_dir/$cd->{id}\n";
      $cd = undef;
   }

   return $cd;
}

my $connect_db;
sub connect_db {

   $dbuser or die "dbuser is empty\n";
   $dbname or die "dbname is empty\n";

   $dbh = DBI->connect("DBI:mysql:$dbname:$dbhost", $dbuser,$dbpass) or 
          die $DBI::errstr;
}

my $disconnect_db;
sub disconnect_db {
   $dbh->disconnect or 
   die $DBI::errstr;
}

my $print_report;
sub print_report {
   my $cd = shift;

   print "\nCategory: $cd->{cat}\n";
   print "DiscID  : $cd->{id}\n";
   print "Artist  : $cd->{artist}\n";
   print "Title   : $cd->{title}\n";
   print "Year    : $cd->{year}\n";
   print "Tracks  : $cd->{tno}\n";
   print "\n";

   my $num = 0;
   foreach my $track (@{$cd->{track}}) {
      $num++;
      print "$num. $track\n";
   }
   print "\n";
}

my $edit_cd_info;
sub edit_cd_info {
   my $cd = shift;
   my %backup_cd;
   my @backup_tracks;
   my $user_input = "z";

   %backup_cd = %{$cd};
   @backup_tracks = @{$cd->{track}};
   while ((lc($user_input) ne "s") && (lc($user_input) ne "x")) {
      print "\n[c] Category: $cd->{cat}\n";
      print "[d] DiscID  : $cd->{id}\n";
      print "[a] Artist  : $cd->{artist}\n";
      print "[t] Title   : $cd->{title}\n";
      print "[y] Year    : $cd->{year}\n";
      print "\n";

      my $num = 0;
      foreach my $track (@{$cd->{track}}) {
         $num++;
         print "[$num] $track\n";
      }
      print "\n[s] save\n";
      print "[x] abort and exit\n";
      print "choice? ([s]/c/d/a/t/y/#/x) ";

      $user_input = <STDIN>;
      chomp($user_input);
      if (lc($user_input) eq "c") {
         print "Category: ";
         $cd->{cat} = <STDIN>;
         chomp($cd->{cat});
      } elsif (lc($user_input) eq "d") {
         print "DiscID: ";
         $cd->{id} = <STDIN>;
         chomp($cd->{id});
      } elsif (lc($user_input) eq "a") {
         print "Artist: ";
         $cd->{artist} = <STDIN>;
         chomp($cd->{artist});
      } elsif (lc($user_input) eq "t") {
         print "Title: ";
         $cd->{title} = <STDIN>;
         chomp($cd->{title});
      } elsif (lc($user_input) eq "y") {
         print "Year: ";
         $cd->{year} = <STDIN>;
         chomp($cd->{year});
      } elsif (lc($user_input) eq "") {
         $user_input = "s";
      } elsif (lc($user_input) eq "x") {
         %{$cd} = %backup_cd;
         $cd->{track} = \@backup_tracks;
      } elsif (($user_input =~ m/^\d+$/) && ($user_input <= $cd->{tno})) {
         print "$user_input: ";
         ${$cd->{track}}[$user_input-1] = <STDIN>;
         chomp(${$cd->{track}}[$user_input-1]);
      }
   }
}

my $display_report;
sub display_report {
   my $ARTIST_NAME;
   my $CD_TITLE;
   my $CD_ID;

format STDOUT_TOP =
 Id Artist                     CD Title                         -- Page @<
$%
--- -------------------------  -------------------------------------------------
.

format STDOUT =
@## @<<<<<<<<<<<<<<<<<<<<<<<<  ^<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
$CD_ID, $ARTIST_NAME,              $CD_TITLE
.

   my $sql = qq(SELECT a.ARTIST_NAME, c.CD_TITLE, c.CD_ID );
   $sql .= qq(FROM CD AS c, Artist AS a );
   $sql .= qq(WHERE c.ARTIST_ID = a.ARTIST_ID );
   $sql .= qq(ORDER BY a.ARTIST_NAME, c.CD_YEAR, c.CD_TITLE);

   my $sth = $dbh->prepare($sql);
   die "DBI error with prepare:", $sth->errstr unless $sth;

   my $result = $sth->execute;
   die "DBI error with execute:", $sth->errstr unless $result;

   my $row;
   while ($row = $sth->fetchrow_hashref) {
      $ARTIST_NAME = $row->{ARTIST_NAME};
      $CD_TITLE = $row->{CD_TITLE};
      $CD_ID = $row->{CD_ID};
      write (STDOUT);
   }

   # Finish that database call
   $sth->finish;

   exit;
}


# __EOF__

