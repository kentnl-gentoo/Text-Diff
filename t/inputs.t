#!/usr/local/bin/perl -w

use strict ;
use Test ;
use Text::Diff ;

my @A = map "$_\n", qw( 1 2 3 4 ) ;
my @B = map "$_\n", qw( 1 2 3 5 ) ;

my $A = join "", @A ;
my $B = join "", @B ;

my $Af = "io_A" ;
my $Bf = "io_B" ;

open A, ">$Af" or die $! ; print A @A or die $! ; close A or die $! ;
open B, ">$Bf" or die $! ; print B @B or die $! ; close B or die $! ;

my @tests = (
sub { ok !diff \@A, \@A },
sub { ok  diff \@A, \@B },
sub { ok !diff \$A, \$A },
sub { ok  diff \$A, \$B },
sub { ok !diff $Af, $Af },
sub { ok  diff $Af, $Bf },
sub { 
    open A1, "<$Af" or die $! ;
    open A2, "<$Af" or die $! ;
    ok !diff \*A1, \*A2 ;
},
sub { 
    open A, "<$Af" or die $! ;
    open B, "<$Bf" or die $! ;
    ok diff \*A, \*B ;
},
sub {
    ok !diff sub { \@A}, sub { \@A } ;
},
sub {
    ok diff sub { \@A }, sub { \@B } ;
},
) ;

plan tests => scalar @tests ;

$_->() for @tests ;

unlink "io_A" or warn $! ;
unlink "io_B" or warn $! ;
