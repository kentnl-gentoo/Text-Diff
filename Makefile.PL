BEGIN { use Config; @INC = grep index( $_, ( defined $Config{sitelib_stem} && length $Config{sitelib_stem} ) ? $Config{sitelib_stem} : $Config{sitelibexp}  ), @INC }
use ExtUtils::MakeMaker;

use strict ;

WriteMakefile(
    'NAME'          => 'Text::Diff',
    'VERSION_FROM'  => 'lib/Text/Diff.pm',
    'PREREQ_PM'     => {
        'Algorithm::Diff'  => 0,
    },
);

sub MY::libscan {
   package MY ;
   my $self = shift ;
   my ( $path ) = @_ ;
   return '' if /\.sw[a-z]$/ ;
   return '' unless length $self->SUPER::libscan( $path ) ;
   return $path ;
}
