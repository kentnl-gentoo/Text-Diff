#!/usr/local/bin/perl -w

use strict ;
use Test ;
use Text::Diff ;
use Algorithm::Diff qw( traverse_sequences ) ;

## Each of these results in one test file.  Each specifies options to pass
## to "diff" right now, and options to pass to Diff when the tests are run.
my @tests= (
    ["-u", 
        ''
    ],
    ["-c",
        'STYLE => "Context"'
    ],
    ["-C0",
        'STYLE => "Context", LINES_OF_CONTEXT => 0'
    ],
    ["-U0",
        'STYLE => "Unified", LINES_OF_CONTEXT => 0'
    ],
    ["",
        'STYLE => "OldStyle"'     
    ],
) ;

my @A = map "$_\n", qw( 1 2 3 4 5d 6 7 8 9    10 11 11d 12 13 ) ;
my @B = map "$_\n", qw( 1 2 3 4 5a 6 7 8 9 9a 10 11     12 13 ) ;

my $sep = ( "----8<----" x 7 ) . "\n" ;

if ( grep "--update", @ARGV ) {
    my $version = `diff -v` ;

    die "Could not determine your diff's version"
        unless defined $version && length $version ;
    chomp $version ;
    die "Requires GNU's diff, not '$version'" 
        unless $version =~ /GNU/ ;

    ## Here are the two files to feed to diff
    open A, ">A" or die $! ; print A @A ; close A ;
    open B, ">B" or die $! ; print B @B ; close B ;

    my $A_mtime = (stat "A")[9] ; 
    my $B_mtime = (stat "B")[9] ; 
    my $file_options = <<END_OPTIONS ;
FILENAME_A => "A",
MTIME_A => $A_mtime,
FILENAME_B => "B",
MTIME_B => $B_mtime
END_OPTIONS

    open ME, "<$0" or die $! ;
    my $me = join( "", <ME> ) ;
    close ME or die $! ;

    open BAK, ">$0.bak" or die $! ;
    print BAK $me or die $! ;
    close BAK or die $! ;

    $me =~ s/^(__DATA__\n).*//ms ;
    open ME, ">$0" or die $! ;
    print ME
        $me,
        "__DATA__\n",
        join(
            $sep, 
            "$file_options\n",
            map( "" . `diff $_->[0] A B`, @tests ),
        )
    or die $! ;

    close ME or die $! ;
#    unlink "A" or warn "$! unlinking A" ;
#    unlink "B" or warn "$! unlinking B" ;
    exit 0 ;
}

## Ok, we're not updating, so run the tests...

my @data = split $sep, join "", <DATA> ;
close DATA or die $! ;
die "Found " . @data,
    " elements, not ", ( @tests + 1 ),
    ", time to --update?\n"
    unless @data == @tests + 1 ;

my @file_options = eval "(" . shift( @data ) . ")" ;
die if $@ ;

plan tests => scalar @tests ;
for ( @tests ) {
    my ( $diff_opts, $Diff_opts ) = @$_ ;
    my $expect = shift @data ;

    my @Diff_opts = eval "($Diff_opts)" ;
    die if $@ ;

    my $output = diff \@A, \@B, { @file_options, @Diff_opts } ;
    if ( $output eq $expect ) {
        ok( 1 ) ;
    }
    else {
        ok( 0 ) ;
        warn "# diff options: $diff_opts\n" ;
        warn "# my options: $Diff_opts\n" ;
        ## Merge the outputs using A::D
        my @E = split /^/g, $expect ;
        my @G = split /^/g, $output ;
        my $w = length "Expected" ;
        for ( @E, @G ) {
            s/\n/\\n/g ;
            $w = length if length > $w ;
        }
        my $fmt = "# %-${w}s %-2s %-${w}s\n" ;
        printf STDERR $fmt, "Expected", " ", "Got" ;
        print STDERR "# ", "-" x ( $w * 2 + 4 ), "\n" ;

        my ( $E_start, $G_start ) ;
        my $print_diff = sub {
	    my ( $E_end, $G_end ) = @_ ;
            if ( defined $E_start || defined $G_start ) {
                while ( $E_start < $E_end || $G_start < $G_end ) {
                    printf STDERR (
                        $fmt,
                        $E_start < $E_end ? $E[$E_start] : "",
                        "!=",
                        $G_start < $G_end ? $G[$G_start] : ""
		     ) ;

		     ++$E_start ;
		     ++$G_start ;
                }
                $E_start = $G_start = undef ;
                
            }
        } ;

	my $dis = sub {
	   $E_start = $_[0] unless defined $E_start ;
	   $G_start = $_[1] unless defined $G_start ;
	} ;

        traverse_sequences(
            \@E, \@G,
            {
                MATCH => sub {
                    $print_diff->( @_ ) ;
                    printf STDERR $fmt, $E[$_[0]], "==", $G[$_[1]] ;
                },
                DISCARD_A => $dis,
                DISCARD_B => $dis,
            }
        ) ;
        $print_diff->( scalar @E, scalar @G ) ;

        print STDERR "# ", "-" x ( $w * 2 + 4 ), "\n" ;
        print STDERR "#\n" ;
    }
}


__DATA__
FILENAME_A => "A",
MTIME_A => 1007888157,
FILENAME_B => "B",
MTIME_B => 1007888157

----8<--------8<--------8<--------8<--------8<--------8<--------8<----
--- A	Sun Dec  9 03:55:57 2001
+++ B	Sun Dec  9 03:55:57 2001
@@ -2,13 +2,13 @@
 2
 3
 4
-5d
+5a
 6
 7
 8
 9
+9a
 10
 11
-11d
 12
 13
----8<--------8<--------8<--------8<--------8<--------8<--------8<----
*** A	Sun Dec  9 03:55:57 2001
--- B	Sun Dec  9 03:55:57 2001
***************
*** 2,14 ****
  2
  3
  4
! 5d
  6
  7
  8
  9
  10
  11
- 11d
  12
  13
--- 2,14 ----
  2
  3
  4
! 5a
  6
  7
  8
  9
+ 9a
  10
  11
  12
  13
----8<--------8<--------8<--------8<--------8<--------8<--------8<----
*** A	Sun Dec  9 03:55:57 2001
--- B	Sun Dec  9 03:55:57 2001
***************
*** 5 ****
! 5d
--- 5 ----
! 5a
***************
*** 9 ****
--- 10 ----
+ 9a
***************
*** 12 ****
- 11d
--- 12 ----
----8<--------8<--------8<--------8<--------8<--------8<--------8<----
--- A	Sun Dec  9 03:55:57 2001
+++ B	Sun Dec  9 03:55:57 2001
@@ -5 +5 @@
-5d
+5a
@@ -9,0 +10 @@
+9a
@@ -12 +12,0 @@
-11d
----8<--------8<--------8<--------8<--------8<--------8<--------8<----
5c5
< 5d
---
> 5a
9a10
> 9a
12d12
< 11d
