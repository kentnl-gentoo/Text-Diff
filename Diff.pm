package Text::Diff ;

$VERSION = 0.1 ;

=head1 NAME

Text::Diff - Unified, context, and "old-style" diffs for lines and other records

=head1 SYNOPSIS

    use Text::Diff ;

    ## Mix and match filenames, strings, file handles, producer subs,
    ## or arrays of records; returns diff in a string.
    ## WARNING: can return B<large> diffs for large files.
    my $diff = diff "file1.txt", "file2.txt", { STYLE => "Context" } ;
    my $diff = diff \$string1,   \$string2,   \%options  ;
    my $diff = diff \*FH1,       \*FH2 ;
    my $diff = diff \&reader1,   \&reader2 ;
    my $diff = diff \@records1,  \@records2 ;

    ## May also mix input types:
    my $diff = diff \@records1,  "file_B.txt" ;

=head1 DESCRIPTION

C<diff()> provides a basic set of services akin to the GNU C<diff> utility.  It
is not anywhere near as feature complete as GNU C<diff>, but it is better
integrated with Perl and available on all platforms.  It is often faster than
shelling out to a system's C<diff> executable for smaller files, and generally
slower on larger files.

Relies on L<Algorithm::Diff> for, well, the algorithm.  This may not produce
the same exact diff as a system's local C<diff> executable, but it will be a
valid diff and comprehensible by C<patch>.

B<Note>: If you don't want to import the C<diff> function, do one of the
following:

   use Text::Diff () ;

   require Text::Diff ;

That's a pretty rare occurence, so C<diff()> is exported by default.

=cut

use Exporter ;
@ISA = qw( Exporter ) ;
@EXPORT = qw( diff ) ;

use strict ;
use Carp ;
use Algorithm::Diff qw( traverse_sequences ) ;

## Hunks are made of ops.  An op is the starting index for each
## sequence and the opcode:
use constant A       => 0 ;   # Array index before match/discard
use constant B       => 1 ;
use constant OPCODE  => 2 ;   # "-", " ", "+"
use constant FLAG    => 3 ;   # What to display if not OPCODE "!"


=head1 OPTIONS

diff() takes two parameters from which to draw input and a set of
options to control it's output.  The options are:

=over

=item FILENAME_A, MTIME_A

The name of the file and the modification time to output for the first
(older/from) file.  Unused on C<OldStyle> diffs.

=item FILENAME_B, MTIME_B

The name of the file and the modification time to output for the second
(newer/to) file.

=item FILENAME_PREFIX_A, FILENAME_PREFIX_B

The string to print before the filename in the header. Unused on C<OldStyle>
diffs.  Defaults are C<"---">, C<"+++"> for Unified and C<"***">, C<"+++"> for
Context.

=item STYLE

"Unified", "Context", "OldStyle", or an object or class reference for a
class providing C<header()>, C<hunk()>, and C<footer()> methods.

Defaults to "Unified" (unlike standard C<diff>, but Unified is what's most
often used in submitting patches and is the most human readable of the three.

=item LINES_OF_CONTEXT

How many lines before and after each diff to display.  Ignored on old-style
diffs.  Defauls to 3.

=item OUTPUT

Examples and their equivalent subroutines:

    OUTPUT   => \*FOOHANDLE,   # like: sub { print FOOHANDLE shift() }
    OUTPUT   => \$output,      # like: sub { $output .= shift }
    OUTPUT   => \@output,      # like: sub { push @output, shift }
    OUTPUT   => sub { $output .= shift },

If no C<OUTPUT> is supplied, returns the diffs in a string.  If
C<OUTPUT> is a C<CODE> ref, it will be called once with the (optional)
file header, and once for each hunk body with the text to emit.  If
C<OUTPUT> is an L<IO::Handle>, output will be emitted to that handle.

=item KEYGEN, KEYGEN_ARGS

These are passed to L<Algorithm::Diff/traverse_sequences>.

=back

B<Note>: if neither C<FILENAME_> option is defined, the header will not be
printed.  If at one is present, the other and both MTIME_ options must be
present or "Use of undefined variable" warnings will be generated (except
on C<OldStyle> diffs, which ignores these options).

=cut

$SIG{__DIE__} = \&Carp::confess ;

my %internal_styles = ( Unified => undef, Context => undef, OldStyle => undef );

sub diff {
    my @seqs = ( shift, shift ) ;
    my $options = shift || {} ;

    for ( @seqs ) {
        $_ = $_->( $options ) while ref eq "CODE" ;

        if ( ref eq "ARRAY" ) {
            ## This is most efficient :)
        }
        elsif ( ref eq "SCALAR" ) {
            $_ = [split( /^/m, $_ )] ;
        }
        elsif ( ! ref ) {
            local $/ = "\n" ;
            open F, "<$_" or carp "$!: $_" ;
            $_ = [<F>] ;
            close F ;
        }
        elsif ( ref eq "GLOB" || UNIVERSAL::isa( $_, "IO::Handle" ) ) {
            local $/ = "\n" ;
            $_ = [<$_>] ;
        }
        else {
            confess "Can't handle input of type ", ref ;
        }
    }

    ## Config vars
    my $output ;
    my $output_handler = $options->{OUTPUT} ;
    for ( $output_handler ) {
        if ( ! defined ) {
            $_ = sub { $output .= shift } ;
        }
        elsif ( ref eq "SCALAR" ) {
            my $out_ref = $_ ;
            $output_handler = sub { $$out_ref .= shift } ;
        }
        elsif ( ref eq "ARRAY" ) {
            my $out_ref = $_ ;
            $output_handler = sub { push @$out_ref, shift } ;
        }
        elsif ( ! defined ) {
            $_ = sub { $output .= shift } ;
        }
        elsif ( ref eq "GLOB" || UNIVERSAL::isa $_, "IO::Handle" ) {
            my $output_handle = $_ ;
            $_ = sub { print $output_handle shift } ;
        }
    }

    my $style  = $options->{STYLE} ;
    $style = "Unified" unless defined $options->{STYLE}  ;
    $style = "Text::Diff::$style" if exists $internal_styles{$style} ;

    my $ctx_lines = $options->{LINES_OF_CONTEXT} ;
    $ctx_lines = 3 unless defined $ctx_lines ;
    $ctx_lines = 0 if $style eq "Text::Diff::OldStyle" ;

    my @keygen_args = $options->{KEYGEN_ARGS}
        ? @{$options->{KEYGEN_ARGS}}
        : () ;

    ## State vars
    my $diffs = 0 ; ## Number of discards this hunk
    my $ctx   = 0 ; ## Number of " " (ctx_lines) ops pushed after last diff.
    my @ops ;       ## ops (" ", +, -) in this hunk
    my $hunks = 0 ; ## Number of hunks

    my $emit_ops = sub {
        $output_handler->( $style->header( $options ) ) unless $hunks++ ;
        $output_handler->( $style->hunk( @seqs, @_, $options ) ) ;
    } ;

    ## We keep 2*ctx_lines so that if a diff occurs
    ## at 2*ctx_lines we continue to grow the hunk instead
    ## of emitting diffs and context as we go. We
    ## need to know the total length of both of the two
    ## subsequences so the line count can be printed in the
    ## header.
    my $dis_a = sub {push @ops, [@_[0,1],"-"] ; ++$diffs ; $ctx = 0 };
    my $dis_b = sub {push @ops, [@_[0,1],"+"] ; ++$diffs ; $ctx = 0 };

    traverse_sequences(
        @seqs,
        {
            MATCH => sub {
                push @ops, [@_[0,1]," "] ;

                if ( $diffs && ++$ctx > $ctx_lines * 2 ) {
        	   $emit_ops->( [ splice @ops, 0, $#ops - $ctx_lines ] );
        	   $ctx = $diffs = 0 ;
                }

                ## throw away context lines that aren't needed any more
                shift @ops if ! $diffs && @ops > $ctx_lines ;
            },
            DISCARD_A => $dis_a,
            DISCARD_B => $dis_b,
        },
        $options->{KEYGEN},  # pass in user arguments for key gen function
        @keygen_args,
    ) ;

    if ( $diffs ) {
        $#ops -= $ctx - $ctx_lines if $ctx > $ctx_lines ;
        $emit_ops->( \@ops ) ;
    }

    $output_handler->( $style->footer( $options ) ) if $hunks ;

    return defined $output ? $output : $hunks ;
}


sub _header {
    my ( $h ) = @_ ;
    my ( $p1, $fn1, $t1, $p2, $fn2, $t2 ) = @{$h}{
        "FILENAME_PREFIX_A",
        "FILENAME_A",
        "MTIME_A",
        "FILENAME_PREFIX_B",
        "FILENAME_B",
        "MTIME_B"
    } ;

    return "" unless defined $fn1 && defined $fn2 ;

    return join( "",
        $p1, " ", $fn1, defined $t1 ? "\t" . localtime $t1 : (), "\n",
        $p2, " ", $fn2, defined $t2 ? "\t" . localtime $t2 : (), "\n",
    ) ;
}

=back

=cut

## _range encapsulates the building of, well, ranges.  Turns out there are
## a few nuances.
sub _range {
    my ( $ops, $a_or_b, $format ) = @_ ;

    my $start = $ops->[ 0]->[$a_or_b] ;
    my $after = $ops->[-1]->[$a_or_b] ;

    ## The sequence indexes in the lines are from *before* the OPCODE is
    ## executed, so we bump the last index up unless the OP indicates
    ## it didn't change.
    ++$after
        unless $ops->[-1]->[OPCODE] eq ( $a_or_b == A ? "+" : "-" ) ;

    ## convert from 0..n index to 1..(n+1) line number.  The unless modifier
    ## handles diffs with no context, where only one file is affected.  In this
    ## case $start == $after indicates an empty range, and the $start must
    ## not be incremented.
    my $empty_range = $start == $after ;
    ++$start unless $empty_range ;

    return
        $start == $after
            ? $format eq "unified" && $empty_range
                ? "$start,0"
                : $start
            : $format eq "unified"
                ? "$start,".($after-$start+1)
                : "$start,$after";
}


sub _op_to_line {
    my ( $seqs, $op, $a_or_b, $op_prefixes ) = @_ ;

    my $opcode = $op->[OPCODE] ;
    return () unless defined $op_prefixes->{$opcode} ;

    my $op_sym = defined $op->[FLAG] ? $op->[FLAG] : $opcode ;
    $op_sym = $op_prefixes->{$op_sym} ;
    return () unless defined $op_sym ;

    $a_or_b = $op->[OPCODE] ne "+" ? 0 : 1 unless defined $a_or_b ;
    return ( $op_sym, $seqs->[$a_or_b][$op->[$a_or_b]] ) ;
}


=head1 Formatting Classes

These functions implement the output formats.  They are grouped in to classes
so diff() can use class names to call the correct set of output routines and so
that you may inherit from them easily.  There are no constructors or instance
methods for these classes, though subclasses may provide them if need be.

Each class has header(), hunk(), and footer() methods identical to those
documented in the Text::Diff::Unified section.  header() is called before the
hunk() is first called, footer() afterwards.  The default footer function
is an empty method provided for overloading:

    sub footer { return "End of patch\n" }

=over

=head2 Text::Diff::Unified

    --- A   Mon Nov 12 23:49:30 2001
    +++ B   Mon Nov 12 23:49:30 2001
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

=over

=item header

    $s = Text::Diff::Unified->header( $options ) ;

Returns a string containing a unified header.  The sole parameter is the
options hash passed in to diff(), containing at least:

    FILENAME_A  => $fn1,
    MTIME_A     => $mtime1,
    FILENAME_B  => $fn2,
    MTIME_B     => $mtime2

May also contain

    FILENAME_PREFIX_A    => "---",
    FILENAME_PREFIX_B    => "+++",

to override the default prefixes (default values shown).

=cut

sub Text::Diff::Unified::header {
    shift ; ## No instance data
    my ( $options ) = @_ ;

    _header(
        { FILENAME_PREFIX_A => "---", FILENAME_PREFIX_B => "+++", %$options }
    ) ;
}

=item Text::Diff::Unified::hunk

    Text::Diff::Unified->hunk( \@seq_a, \@seq_b, \@ops, $options ) ;

Returns a string containing the output of one hunk of unified diff.

=cut

sub Text::Diff::Unified::hunk {
    shift ; ## No instance data
    pop   ; ## Ignore options
    my $ops = pop ;
    ## Leave the sequences in @_[0,1]

    my $prefixes = { "+" => "+", " " => " ", "-" => "-" } ;

    return join( "",
        "@@ -",
        _range( $ops, A, "unified" ),
        " +",
        _range( $ops, B, "unified" ),
        " @@\n",
        map _op_to_line( \@_, $_, undef, $prefixes ), @$ops
    ) ;
}


=item footer

    $s = Text::Diff::Unified->footer( $options ) ;

Returns C<"">.

=cut

sub Text::Diff::Unified::footer { "" }

=back

=head2 Text::Diff::Context

    *** A   Mon Nov 12 23:49:30 2001
    --- B   Mon Nov 12 23:49:30 2001
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

=cut


sub Text::Diff::Context::header {
    _header { FILENAME_PREFIX_A => "***", FILENAME_PREFIX_B => "---", %{$_[1]} } ;
}


sub Text::Diff::Context::hunk {
    shift ; ## No instance data
    pop   ; ## Ignore options
    my $ops = pop ;
    ## Leave the sequences in @_[0,1]

    my $a_range = _range( $ops, A, "" ) ;
    my $b_range = _range( $ops, B, "" ) ;

    ## Sigh.  Gotta make sure that differences that aren't adds/deletions
    ## get prefixed with "!", and that the old opcodes are removed.
    my $after ;
    for ( my $start = 0 ; $start <= $#$ops ; $start = $after ) {
        ## Scan until next difference
        $after = $start + 1 ;
        my $opcode = $ops->[$start]->[OPCODE] ;
        next if $opcode eq " " ;

        my $bang_it ;
        while ( $after <= $#$ops && $ops->[$after]->[OPCODE] ne " " ) {
            $bang_it ||= $ops->[$after]->[OPCODE] ne $opcode ;
            ++$after ;
        }

        if ( $bang_it ) {
            for my $i ( $start..($after-1) ) {
                $ops->[$i]->[FLAG] = "!" ;
            }
        }
    }

    my $b_prefixes = { "+" => "+ ",  " " => "  ", "-" => undef, "!" => "! " };
    my $a_prefixes = { "+" => undef, " " => "  ", "-" => "- ",  "!" => "! " };

    return join( "",
        "***************\n",
        "*** ", $a_range, " ****\n",
        map( _op_to_line( \@_, $_, A, $a_prefixes ), @$ops ),
        "--- ", $b_range, " ----\n",
        map( _op_to_line( \@_, $_, B, $b_prefixes ), @$ops ),
    ) ;
}

sub Text::Diff::Context::footer { "" }

=head2 Text::Diff::OldStyle

    5c5
    < 5d
    ---
    > 5a
    9a10
    > 9a
    12d12
    < 11d

Note: no header, Text::Diff::OldStyle::header always returns C<"">.

=cut

sub Text::Diff::OldStyle::header { "" }

sub Text::Diff::OldStyle::hunk {
    shift ; ## No instance data
    pop   ; ## ignore options
    my $ops = pop ;
    ## Leave the sequences in @_[0,1]

    my $a_range = _range( $ops, A, "" ) ;
    my $b_range = _range( $ops, B, "" ) ;

    my $a_prefixes = { "+" => undef,  " " => undef, "-" => "< "  } ;
    my $b_prefixes = { "+" => "> ",   " " => undef, "-" => undef } ;

    my $op = $ops->[0]->[OPCODE] ;
    $op = "c" if grep $_->[OPCODE] ne $op, @$ops ;
    $op = "a" if $op eq "+" ;
    $op = "d" if $op eq "-" ;

    return join( "",
        $a_range, $op, $b_range, "\n",
        map( _op_to_line( \@_, $_, A, $a_prefixes ), @$ops ),
        $op eq "c" ? "---\n" : (),
        map( _op_to_line( \@_, $_, B, $b_prefixes ), @$ops ),
    ) ;
}

sub Text::Diff::OldStyle::footer { "" }

=head1 LIMITATIONS

Must suck both input files entirely in to memory and store them with a normal
amount of Perlish overhead (one array location) per record.  This is implied by
the implementation of Algorithm::Diff, which takes two arrays.  If
Algorithm::Diff ever offers and incremental mode, this can be changed (contact
the maintainers of Algorithm::Diff and Text::Diff if you need this; it
shouldn't be too terribly hard to tie arrays in this fashion).

Does not provide most of the more refined GNU diff options: recursive directory
tree scanning, ignoring blank lines / whitespace, etc., etc.  These can all be
added as time permits and need arises, many are rather easy; patches quite
welcome.

Uses closures internally, this may lead to leaks on C<perl> versions 5.6.1 and
prior if used many times over a process' life time.

=head1 AUTHOR

Barrie Slaymaker <barries@slaysys.com>.

=head1 COPYRIGHT & LICENSE

Copyright 2001, Barrie Slaymaker.  All Rights Reserved.

You may use this under the terms of either the Artistic License or GNU Public
License v 2.0 or greater.

=cut

1 ;
