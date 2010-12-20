package App::cpanpq;

#ABSTRACT: the guts of the cpanpq command

use strict;
use warnings;
use Module::Load::Conditional qw[check_install];
use CPANPLUS::Internals::Constants;
use CPANPLUS::Configure;
use CPANPLUS::Error;
use CPANPLUS::Backend;
use Getopt::Long;
use Term::UI;
use Term::ReadLine;
use File::Path qw[mkpath];
use File::Spec;
use File::Fetch;
use File::Find;
use IO::Zlib;
use version;

$ENV{PERL_MM_USE_DEFAULT} = 1; # despite verbose setting
$ENV{PERL_EXTUTILS_AUTOINSTALL} = '--defaultdeps';

sub run {
  my $package = shift;
  my %opts = @_;
  $opts{lc $_} = delete $opts{$_} for keys %opts;
  my $dir = _get_dir();
  mkpath $dir unless -d $dir;
  $opts{_dir} = $dir;
  delete $opts{cb};
  my $self = bless \%opts, $package;
  $self->{skiplist} = File::Spec->catfile( $dir, 'skiplist' );
  if ( -e $self->{skiplist} ) {
    open my $skip, '<', 'skiplist' or die "Could not open skiplist: $!\n";
    while( <$skip> ) {
      chomp;
      my ($vers,$path) = split /\s+/;
      next unless $vers eq $];
      $self->{skip}->{ $path }++;
    }
  }
  my ($inst,$uninst,$update,$all);
  # getopts or usage();
  # If install or uninstall, loop over @ARGV.
  #   - if no @ARGVs read from STDIN
  # If update call update, if all set interactive = 0
  GetOptions( 
      'install'   => \$inst,
      'uninstall' => \$uninst,
      'update'    => \$update,
      'all'       => \$all,
  );
  SWITCH: {
    # update trumps everything.
    if ( $update ) {
      $self->{interactive} = $all ? '0' : '1';
      $self->update();
      last SWITCH;
    }
    # $inst or $uninst 
    if ( $inst and $uninst ) {
      $uninst = '';
    }
    unless ( $inst or $uninst ) {
      $inst = 1;
    }
    if ( $inst or $uninst ) {
      my $method;
      $method = 'install'   if $inst;
      $method = 'uninstall' if $uninst;
      if ( scalar @ARGV ) {
        $self->$method( $_ ) for @ARGV;
      }
      else {
        while ( <> ) {
          chomp;
          $self->$method( $_ );
        }
      }
      last SWITCH;
    }
  }
  return 1;
}

sub install {
  my $self = shift;
  my $mod = shift || return;
  my $test = 0;
  $self->{cb} ||= _backend();
  my $module = $self->{cb}->parse_module( module => $mod );
  return unless $module;
  CPANPLUS::Error->flush();
  $module->install( ( $test ? ( target => 'create' ) : () ) );
}

sub uninstall {
  my $self = shift;
  my $mod = shift || return;
  $self->{cb} ||= _backend();
  my $module = $self->{cb}->parse_module( module => $mod );
  return unless $module;
  CPANPLUS::Error->flush();
  $module->uninstall();
}

sub update {
  my $self = shift;
  
  my %installed;

  foreach my $module ( _all_installed() ) {
    my $href = check_install( module => $module );
    next unless $href;
    $installed{ $module } = defined $href->{version} ? $href->{version} : 'undef';
  }

  $self->{cb} ||= _backend();

  my $mirrors = $self->{cb}->configure_object()->get_conf('hosts');

  my $loc;

  for ( @{ $mirrors } ) {
    my $mirror = $self->{cb}->_host_to_uri( %{ $_ } );
    $loc = _fetch_indexes($self->{_dir}, $mirror );
    last if $loc;
  }

  die "Failed to download indexes\n" unless $loc;

  $self->_populate_cpan( $loc );

  my %seen;
  foreach my $module ( sort keys %installed ) {
    # Eliminate core modules
    if ( _supplied_with_core( $module ) and !$self->{cpan}->{ $module } ) {
      delete $installed{ $module };
      next;
    }
    if ( !$self->{cpan}->{ $module } ) {
      delete $installed{ $module };
      next;
    }
    if ( $module =~ /^Bundle::/ ) {
      delete $installed{ $module };
      next;
    }
    if ( $seen{ $self->{cpan}->{ $module }->[1] } ) {
      delete $installed{ $module };
      next;
    }
    $seen{ $self->{cpan}->{ $module }->[1] }++;
    unless ( _vcmp( $self->{cpan}->{ $module }->[0], $installed{ $module} ) > 0 ) {
      delete $installed{ $module };
      next;
    }
    if ( $self->{cpan}->{ $module }->[1] and $self->{cpan}->{ $module }->[1] =~ m{\w/\w{2}/\w+/perl-\S+tar\.gz$}i ) {
      delete $installed{ $module };
      next;
    }
  }

  # Eliminate if in the skiplist

  foreach my $module ( sort keys %installed ) {
    my $package = $self->{cpan}->{ $module }->[1];
    if ( $self->{skip}->{ $package } ) {
      delete $installed{ $module };
      next;
    }
  }

  # Eliminate more by asking the user if interactive

  if ( $self->{interactive} ) {
    my $term = Term::ReadLine->new('brand');

    foreach my $module ( sort keys %installed ) {
      my $package = $self->{cpan}->{ $module }->[1];
      unless ( $term->ask_yn(
        prompt => "Update package '$package' for '$module' ?",
        default => 'y',
      ) ) {
        delete $installed{ $module };
        if ( $term->ask_yn( prompt => 'Do you wish to permanently skip this package ?', default => 'n' ) ) {
          open my $skip, '>>', $self->{skiplist} or die "Could not open skiplist: $!\n";
          print $skip join(' ', $], $package), "\n";
        }
      }
    }

  }

  $self->install( $_ ) for keys %installed;

  return 1;
}

sub _backend {
  # options.
  my $conf = CPANPLUS::Configure->new();
  $conf->set_conf( no_update => '1' );
  # Choose between CPANIDX and CPANMetaDB
  $conf->set_conf( source_engine => 'CPANPLUS::Internals::Source::CPANIDX' );
  if ( check_install( module => 'CPANPLUS::Dist::YACSmoke' ) ) {
    $conf->set_conf( dist_type => 'CPANPLUS::Dist::YACSmoke' );
    $conf->set_conf( 'prereqs' => 2 );
  }
  else {
    $conf->set_conf( 'prereqs' => 1 );
  }
  $conf->set_conf( 'verbose' => 1 );
  my $cb = CPANPLUS::Backend->new($conf);
  return $cb;
}

sub _supplied_with_core {
  my $name = shift;
  my $ver = shift || $];
  require Module::CoreList;
  return $Module::CoreList::version{ 0+$ver }->{ $name };
}

sub _vcmp {
  my ($x, $y) = @_;
  s/_//g foreach $x, $y;
  return version->parse($x) <=> version->parse($y);
}

sub _fetch_indexes {
  my ($location,$mirror) = @_;
  my $packages = 'modules/02packages.details.txt.gz';
  my $join = $mirror =~ m!/$! ? '' : '/';
  my $url = join $join, $mirror, $packages;
  my $ff = File::Fetch->new( uri => $url );
  my $stat = $ff->fetch( to => $location );
  return unless $stat;
  return $stat;
}

sub _get_dir {
  my $base = glob('~');
  if ( $base eq '~' and $^O eq 'MSWin32' ) {
      $base = File::Spec->catdir( $ENV{APPDATA}, 'cpanpq' );
  }
  else {
     $base = File::Spec->catdir( $base, '.cpanpq' );
  }
  return $base;
}


sub _populate_cpan {
  my $self = shift;
  my $pfile = shift;
  my $fh = IO::Zlib->new( $pfile, "rb" ) or die "$!\n";
  my %dists;

  while (<$fh>) {
    last if /^\s*$/;
  }
  while (<$fh>) {
    chomp;
    my ($module,$version,$package_path) = split ' ', $_;
    $self->{cpan}->{ $module } = [ $version, $package_path ];
  }
  return 1;
}

sub _all_installed {
    ### File::Find uses follow_skip => 1 by default, which doesn't die
    ### on duplicates, unless they are directories or symlinks.
    ### Ticket #29796 shows this code dying on Alien::WxWidgets,
    ### which uses symlinks.
    ### File::Find doc says to use follow_skip => 2 to ignore duplicates
    ### so this will stop it from dying.
    my %find_args = ( follow_skip => 2 );

    ### File::Find uses lstat, which quietly becomes stat on win32
    ### it then uses -l _ which is not allowed by the statbuffer because
    ### you did a stat, not an lstat (duh!). so don't tell win32 to
    ### follow symlinks, as that will break badly
    $find_args{'follow_fast'} = 1 unless ON_WIN32;

    ### never use the @INC hooks to find installed versions of
    ### modules -- they're just there in case they're not on the
    ### perl install, but the user shouldn't trust them for *other*
    ### modules!
    ### XXX CPANPLUS::inc is now obsolete, remove the calls
    #local @INC = CPANPLUS::inc->original_inc;

    my %seen; my @rv;
    for my $dir (@INC ) {
        next if $dir eq '.';

        ### not a directory after all 
        ### may be coderef or some such
        next unless -d $dir;

        ### make sure to clean up the directories just in case,
        ### as we're making assumptions about the length
        ### This solves rt.cpan issue #19738
        
        ### John M. notes: On VMS cannonpath can not currently handle 
        ### the $dir values that are in UNIX format.
        $dir = File::Spec->canonpath( $dir ) unless ON_VMS;
        
        ### have to use F::S::Unix on VMS, or things will break
        my $file_spec = ON_VMS ? 'File::Spec::Unix' : 'File::Spec';

        ### XXX in some cases File::Find can actually die!
        ### so be safe and wrap it in an eval.
        eval { File::Find::find(
            {   %find_args,
                wanted      => sub {

                    return unless /\.pm$/i;
                    my $mod = $File::Find::name;

                    ### make sure it's in Unix format, as it
                    ### may be in VMS format on VMS;
                    $mod = VMS::Filespec::unixify( $mod ) if ON_VMS;                    
                    
                    $mod = substr($mod, length($dir) + 1, -3);
                    $mod = join '::', $file_spec->splitdir($mod);

                    return if $seen{$mod}++;

                    push @rv, $mod;
                },
            }, $dir
        ) };

    }

    return @rv;
}

qq[Hello, darkness, my old friend];

=begin Pod::Coverage

  install
  uninstall
  update

=end Pod::Coverage

=pod

=head1 SYNOPSIS

  use App::cpanpq;

  App::cpanpq->run();

=head1 DESCRIPTION

App::cpanpq provides the guts of the L<cpanpq> command.

=head1 CONSTRUCTOR

=over

=item C<run>

Executes the L<cpanpq> command.

=back

=cut
