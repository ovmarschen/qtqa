#!/usr/bin/env perl
#############################################################################
##
## Copyright (C) 2012 Nokia Corporation and/or its subsidiary(-ies).
## Contact: http://www.qt-project.org/
##
## This file is part of the Quality Assurance module of the Qt Toolkit.
##
## $QT_BEGIN_LICENSE:LGPL$
## GNU Lesser General Public License Usage
## This file may be used under the terms of the GNU Lesser General Public
## License version 2.1 as published by the Free Software Foundation and
## appearing in the file LICENSE.LGPL included in the packaging of this
## file. Please review the following information to ensure the GNU Lesser
## General Public License version 2.1 requirements will be met:
## http://www.gnu.org/licenses/old-licenses/lgpl-2.1.html.
##
## In addition, as a special exception, Nokia gives you certain additional
## rights. These rights are described in the Nokia Qt LGPL Exception
## version 1.1, included in the file LGPL_EXCEPTION.txt in this package.
##
## GNU General Public License Usage
## Alternatively, this file may be used under the terms of the GNU General
## Public License version 3.0 as published by the Free Software Foundation
## and appearing in the file LICENSE.GPL included in the packaging of this
## file. Please review the following information to ensure the GNU General
## Public License version 3.0 requirements will be met:
## http://www.gnu.org/copyleft/gpl.html.
##
## Other Usage
## Alternatively, this file may be used in accordance with the terms and
## conditions contained in a signed written agreement between you and Nokia.
##
##
##
##
##
##
## $QT_END_LICENSE$
##
#############################################################################

use strict;
use warnings;

=head1 NAME

setup.pl - set up environment for Qt QA scripts

=head1 SYNOPSIS

setup.pl [--install] [--prefix <prefix>]

Attempt to ensure all prerequisites for this repo are installed.

If run with no arguments, this script will check if you have all necessary
perl modules.

The behavior can be customized with the following options:

=over

=item --install

Attempt to automatically install the missing perl modules.

This will attempt to use cpanminus to install into $HOME/perl5
(or the prefix given with the `--prefix' option).

=item  --prefix <prefix>

Customize the prefix used for perl installation.
Defaults to $HOME/perl5 .

Only makes sense combined with `--install'.

=back

=head1 EXAMPLE

The recommend way to run the script is:

C<./setup.pl --install>

This will attempt to automatically install all needed perl modules.

It will automatically install cpanminus (a tool for installing
modules from CPAN) and all required perl modules into `$HOME/perl5'.

If you do it this way, you should ensure your environment is set up to use
the perl modules under `$HOME/perl5'.  The recommended way to do this is to
have this shell fragment

C<eval $(perl -Mlocal::lib)>

...in some script which is sourced in your environment at login time.
See `perldoc L<local::lib>' for more details.

=cut

#==============================================================================

package QtQASetup;

use English               qw( -no_match_vars      );
use File::Spec::Functions qw( catfile devnull     );
use File::Temp            qw( tempfile            );
use Getopt::Long          qw( GetOptionsFromArray );
use LWP::UserAgent        qw(                     );
use Pod::Usage            qw( pod2usage           );

# URL from which cpanminus can be downloaded.
# Note that http://cpanmin.us, as recommended by the docs, is not a good idea;
# it redirects to an https:// site and this requires more modules to be
# installed to handle the SSL.
my $HTTP_CPANMINUS =
    'http://cpansearch.perl.org/src/MIYAGAWA/App-cpanminus-1.4005/bin/cpanm';

my $WINDOWS = ($OSNAME =~ m{win32}i);

#====================== perl stuff ============================================

# Module metadata.
#
# Available metadata is:
#
#  interactive-yes  ->  Instead of installing the standard non-interactive way,
#                       ask CPAN to install this module interatively, and
#                       answer all questions with "y" (yes).  Used for broken
#                       installers.
#
my %CPAN_MODULE_META = (
    'Inline::C' => {
        # installer bug on mac; the compiler is named like gcc-4.2, and
        # Inline installer incorrectly interprets this as a command named
        # "gcc-4" with an executable extension of "2".  It can't find this
        # in PATH, so it disables Inline::C by default.  Luckily, enabling it
        # by passing "y" works fine.
        ($OSNAME =~ m{darwin}i)
            ? ('interactive-yes' => 1)
            : ()
    },
);

# Returns a list of all CPAN modules needed (including those which
# are already installed).
#
# The returned values are suitable for use both as module names within
# a perl script (e.g. use Some::Module), and as module names for use with
# the cpan command (e.g. cpan -D Some::Module).
#
sub all_required_cpan_modules
{
    # available on all platforms...
    my @out = qw(
        Capture::Tiny
        Class::Factory::Util
        Env::Path
        File::chdir
        File::Copy::Recursive
        File::Fetch
        File::Find::Rule
        File::HomeDir
        File::Slurp
        IO::CaptureOutput
        IO::Uncompress::AnyInflate
        Inline::C
        Lingua::EN::Inflect
        Lingua::EN::Numbers
        List::Compare
        List::MoreUtils
        Params::Validate
        Perl::Critic
        Readonly
        Test::Exception
        Test::Exit
        Test::More
        Test::NoWarnings
        Test::Perl::Critic
        Text::Diff
        Text::Trim
        Text::Wrap
        Tie::IxHash
        autodie
    );

    # available everywhere but Windows
    # (actually, some of these modules are possible to install on Windows but
    # don't make sense or are too buggy to be safely used)
    push @out, qw(
        BSD::Resource
        Proc::Reliable
        Tie::Sysctl
    ) unless $WINDOWS;

    # available _only_ on Windows
    push @out, qw(
        Win32::Job
        Win32::Process
    ) if $WINDOWS;

    return @out;
}

# Returns the subset of modules from `all_required_cpan_modules'
# which are not currently installed.
#
# This function invokes perl once per module, and attempts to use each
# module to determine if it is available in the current environment.
# Therefore it is crucial that modules must not have significant side effects
# merely from being used.
#
# Parameters:
#  an optional hashref to be passed to run_module_test
#
sub missing_required_cpan_modules
{
    my ($self, $arg_ref) = @_;

    my @all = $self->all_required_cpan_modules;

    my @need_install = ();

    # We're deliberately running a new `perl' for each module instead of
    # just doing the `require' ourselves.
    #
    # The reason is that attempting to `require' a module may have undesireable
    # side effects. In particular, some modules will refuse to be `require'd
    # more than once, which breaks our case where we want to do:
    #
    #  - attempt to load a module
    #  - if it fails:
    #    - install the module
    #    - attempt to load it again
    #

    foreach my $module (@all) {
        print "$module - ";
        my $cmd = qq{perl -e "require $module; 1"};

        if (!$self->run_module_test( $cmd, $arg_ref )) {
            push @need_install, $module;
        }
    }

    return @need_install;
}

# Install cpanminus to the given $prefix, or die.
#
# This will result in a cpanm command being made available at $prefix/bin/cpanm.
#
# This function fetches cpanminus from the Internet and hence needs an
# Internet connection.
#
# Parameters:
#
#  $prefix  -   the prefix under which cpanminus should be installed
#               (e.g. `$HOME/perl5')
#
sub install_cpanminus
{
    my ($self, $prefix) = @_;

    # We want a simple way to download files from http, which will work on both
    # win and unix, without needing any non-core perl modules.  There seems to
    # be no such thing.
    # However, LWP seems fairly safe to use - although technically not a core module,
    # it is installed by default for ActivePerl and probably most Linux distros.

    my ($tempfh, $tempfilename) = tempfile( 'qtqa-cpanminus.XXXXXX', TMPDIR => 1 );

    my $response = LWP::UserAgent->new( )->get( $HTTP_CPANMINUS );

    die "get $HTTP_CPANMINUS: ".$response->as_string if (!$response->is_success);

    $tempfh->print( $response->decoded_content );
    close( $tempfh ) || die "close $tempfilename: $OS_ERROR";

    my @cmd = (
        'perl',
        $tempfilename,    # contains a copy of the cpanm bootstrap script
        '--local-lib',    # options from this line onwards are cpanm options, not perl options;
        $prefix,          # install to the given prefix
        'App::cpanminus', # name of the module to install is App::cpanminus
    );

    print "+ @cmd\n";
    if (0 != system(@cmd)) {
        die "Could not install cpanminus; install command exited with status $?";
    }
}

# Ask cpan to install the given @modules.
#
# This may result in more than one execution of cpan, depending on the metadata
# of the installed modules.
#
# This function will not retry the cpan command(s).  It does not attempt to
# be robust in case of failure.
#
# Parameters:
#
#  @modules -   list of modules to install (e.g. qw(Date::Calc SOAP::Lite))
#
# Returns the exit status of the cpan command (or the worst exit status, if
# multiple commands were run).
#
sub run_cpan
{
    my ($self, @modules) = @_;

    my $prefix = $self->{locallib};
    my @cpan = (
        "$prefix/bin/cpanm",

        # Install into the local prefix
        "--local-lib", $prefix,

        # Skip autotests.
        # If autotests fail, there's not really any practical way for
        # us to resolve the issue, so there is little point to running
        # the tests.  We merely hope that the quality is not so bad as
        # to cause our scripts to break.  This could be revisited with
        # a more complex solution in the future, e.g. trying to install
        # older versions of modules which fail tests.
        "--notest",
    );

    unless (-e $cpan[0]) {
        print "I need cpanminus and it's not installed yet; installing it myself :)\n";
        # Return instead of die if cpanm installation fails, so our caller can choose
        # to retry if appropriate.
        eval { $self->install_cpanminus($prefix) };
        if ($@) {
            warn "$@\ncpanminus isn't installed, and I failed to install it :(\n";
            return 1;
        }
    }

    my $out = 0;

    my @modules_normal;
    my @modules_yes;
    foreach my $module (@modules) {
        if ($CPAN_MODULE_META{ $module }{ 'interactive-yes' }) {
            push @modules_yes, $module;
        }
        else {
            push @modules_normal, $module;
        }
    }

    if (@modules_normal) {
        print "+ @cpan @modules_normal\n";
        $out ||= system(@cpan, @modules_normal);
    }

    if (@modules_yes) {
        # use interactive installer and answer yes to all
        my @cpan_yes = (
            '/bin/sh',
            '-c',
            'yes | '.join(' ', @cpan, '--interactive', @modules_yes),
        );

        print "+ @cpan_yes\n";
        $out ||= system(@cpan_yes);
    }

    return $out;
}

# Import the local::lib module into the current process or exit.
#
# Importing local::lib ensure the selected prefix exists and is
# available for use by the current process and all subprocesses.
#
# This is equivalent to `use local::lib', except that it will give
# a helpful failure message if local::lib is not available.
#
sub do_local_lib
{
    my ($self) = @_;

    my $prefix = $self->{locallib};
    eval { require local::lib; local::lib->import($prefix) };
    if (!$EVAL_ERROR) {
        return;
    }

    print STDERR
        "$EVAL_ERROR\n\nI need you to manually install the local::lib module "
       ."before I can proceed.  This module allows me to easily set up a perl "
       ."prefix under $prefix.\n";

    # This hint may be helpful to some :)
    if (-e "/etc/debian_version") {
        print STDERR
            "\nOn Debian and Ubuntu, this module is available from the "
           ."`liblocal-lib-perl' package.\n";
    }

    exit 1;
}

# Try hard to ensure all CPAN modules returned from all_required_cpan_modules
# are installed.  The cpan command may be run several times.
#
# Returns 1 on success, 0 on failure.
#
sub ensure_complete_cpan
{
    my $self = shift;

    # We expect everything under a local::lib
    $self->do_local_lib;

    return $self->try_hard_to_install(
        name        =>  "CPAN",
        need_sub    =>  \&missing_required_cpan_modules,
        install_sub =>  \&run_cpan,
    );
}

#====================== generic stuff =========================================

# Create a QtQASetup object.
#
# Parameters:
#
#   @args   -   command-line parameters, e.g. from $ARGV
#               (see perldoc for documentation)
#
sub new
{
    my ($class, @args) = @_;

    my $home = $WINDOWS ? catfile($ENV{HOMEDRIVE}, $ENV{HOMEPATH})
             :            $ENV{HOME};

    my %self = (
        install     =>  0,
        locallib    =>  catfile($home, 'perl5'),
    );

    GetOptionsFromArray(\@args,
        "install"     =>  \$self{install},
        "prefix=s"    =>  \$self{locallib},
        "help"        =>  sub { pod2usage(2) },
    ) || pod2usage(1);

    bless \%self, $class;
    return \%self;
}

# Run the setup procedure, installing all needed modules.
#
# Returns on success, and exits with a non-zero exit code on failure.
#
sub run
{
    my $self = shift;

    # Close STDIN to ensure that all modules and subprocesses do not try to do interactive
    # prompts, etc.
    #
    # Without this, it is possible that certain modules will attempt to read from STDIN
    # and block indefinitely (even though we have not asked pip, cpan to run in interactive
    # mode).
    close( STDIN ) || die "close STDIN: $OS_ERROR";

    print "\nChecking perl modules ...\n";
    if (!$self->ensure_complete_cpan) {
        exit 1;
    }
}

# Try really hard to install some modules.
#
# Takes one hash, with these named parameters:
#
#  name:        user-friendly name of the type of modules we're
#               installing, e.g. "CPAN"
#
#  need_sub:    reference to a sub returning a list of all modules
#               which still need to be installed
#
#  install_sub: reference to a sub which takes as input a list of
#               modules, and attempts to install them
#
# Example:
#
#    # Install all modules from CPAN
#    $self->try_hard_to_install(
#        name        =>  "CPAN",
#        need_sub    =>  \&missing_required_cpan_modules,
#        install_sub =>  \&run_cpan,
#    );
#
# This function will repeatedly call need_sub and install_sub to
# calculate what needs to be installed, and to install them.
# It will stop when need_sub returns an empty list or when no
# progress can be made.
#
# This function is necessary because modules may, on occasion,
# be missing some vital dependency information which
# prevents them from installing correctly on the first attempt.
# As a desireable side effect, it also helps this script to be
# robust in the face of transient network failures.
#
# Returns 1 on success, 0 on failure.
#
sub try_hard_to_install
{
    my ($self, %args) = @_;

    my $name = $args{name};

    my @need = $args{need_sub}($self, { quiet => 1 });

    unless (@need) {
        print "\nIt looks like your $name setup is complete :)\n";
        return 1;
    }

    print "\nYou are missing some needed $name modules.\n";

    unless ($self->{install}) {
        print "I can install them if you use the `--install' option.\n";
        return 0;
    }

    # we'll retry up to this many times, e.g. to recover from temporary network issues.
    my $MAX_TRIES = 8;
    my $tries = 0;
    while (1) {
        my $exitcode = $args{install_sub}($self, @need);
        if ($exitcode == 0) {
            last;
        }

        print "\n\nInstallation failed :(\n";
        print "Checking if any progress was made...\n\n";

        my %newneed = map { $_ => 1 } $args{need_sub}($self, { quiet => 1 });
        my @installed = grep { !$newneed{$_} } @need;

        if (@installed) {
            print "\nAlthough installation failed, it looks like some "
                ."progress was made; successfully installed these:\n\n  "
                .join(" ", @installed)."\n\n";

            @need = keys %newneed;

            if (@need) {
                print "I'll try again to see if I can get further.\n";
            }
            else {
                print "Actually, there's nothing left to install!\n"
                    ."You might want to check why installation claimed "
                    ."to fail. Regardless, I'm continuing.\n";
                last;
            }
        }
        else {
            print "\nNope, looks like no progress was made.  See errors:\n";
            $args{need_sub}($self, { quiet => 0 });
            if ($tries++ < $MAX_TRIES) {
                # wait for 8, 16, 32, 64 ... seconds.
                my $delay = 2**($tries+2);
                print "\nTrying again in $delay seconds [attempt $tries of $MAX_TRIES].\n";
                sleep $delay;
            }
            else {
                print "\nGiving up :(\n";
                return 0;
            }
        }
    }

    @need = $args{need_sub}($self, { quiet => 0 });
    if (@need) {
        print "Installation completed successfully, but you still seem to "
             ."be missing some $name modules: @need\n";
        return 0;
    }

    return 1;
}

# Run a module test command, and return true if it succeeds.
#
# Parameters:
#   $cmd     -  the command to run; will be run via shell, so be careful with quotes
#   $arg_ref -  hashref with the following keys:
#     quiet  => if true, hide stderr from the command
#
sub run_module_test
{
    my ($self, $cmd, $arg_ref) = @_;

    my $quiet = $arg_ref->{ quiet };

    if ($quiet) {
        $cmd .= ' 2>'.devnull();
    }

    if (0 == system($cmd)) {
        print "OK\n";
        return 1;
    }

    # if we hid errors, then we'll print a summary;
    # otherwise, we expect that the module test command printed something.
    if ($quiet) {
        print "NOT OK\n";
    }

    return 0;
}

#==============================================================================

QtQASetup->new(@ARGV)->run if (!caller);
1;
