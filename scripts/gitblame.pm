#!/usr/bin/env perl

#   Copyright (c) MediaTek USA Inc., 2020-2023
#
#   This program is free software;  you can redistribute it and/or modify
#   it under the terms of the GNU General Public License as published by
#   the Free Software Foundation; either version 2 of the License, or (at
#   your option) any later version.
#
#   This program is distributed in the hope that it will be useful, but
#   WITHOUT ANY WARRANTY;  without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
#   General Public License for more details.
#
#   You should have received a copy of the GNU General Public License
#   along with this program;  if not, see
#   <http://www.gnu.org/licenses/>.
#
#
# gitblame [--p4] [--prefix path] [domain] pathname
#
#   This script runs "git blame" for the specified file and formats the result
#   to match the diffcov(1) age/ownership annotation specification.
#
#   If the '--p4' flag is used:
#     we assume that the GIT repo is cloned from Perforce - and look for
#     the line in the generated commit log message which tells us the perforce
#     changelist ID that we actually want.
#
#   If specified, 'path' is prependied to 'pathname' (as 'path/pathname')
#     before processing.
#
#   If passed a domain name (or domain regexp):
#     strip that domain from the author's address, and treat all users outside
#     the matching domain as "External".

package gitblame;
use strict;
use File::Basename qw(dirname basename);
use File::Spec;
use Getopt::Long qw(GetOptionsFromArray);

use annotateutil qw(not_in_repo);

our @ISA       = qw(Exporter);
our @EXPORT_OK = qw(new);

use constant {
              P4     => 0,
              DOMAIN => 1,
              PREFIX => 2,
};

sub new
{
    my $class  = shift;
    my $script = shift;

    my $mapP4;
    my $prefix;
    my @args = @_;

    if (!GetOptionsFromArray(\@_,
                             ("p4"       => \$mapP4,
                              "prefix:s" => \$prefix)
    )) {
        my $exe = basename($script ? $script : $0);
        print(STDERR "usage: $exe [--p4] [domain] pathname\n");
        exit(1) if ($script eq $0);
        return undef;
    }

    my $internal_domain = shift;
    my @prefix;
    push(@prefix, $prefix) if $prefix;
    my $self = [$mapP4, $internal_domain, \@prefix];
    return bless $self, $class;
}

sub annotate
{
    my ($self, $file) = @_;

    my $pathname = File::Spec->catfile(@{$self->[PREFIX]}, $file);
    die("$0 expected readable file, found '" .
        (defined($pathname) ? $pathname : '<undef>') . "'")
        unless defined($pathname) &&
        (-f $pathname || -l $pathname) &&
        -r $pathname;

    # set working directory to account for nested repos and submodules
    my $dir      = dirname($pathname);
    my $basename = basename($pathname);
    -d $dir or die("no such directory '$dir'");

    my %changelists;
    my $status = 0;
    my @lines;

    my $null = File::Spec->devnull();
    if (0 == system("cd $dir ; git rev-parse --show-toplevel >$null 2>&1")) {
        # in a git repo
        if (0 == system(
                 "cd $dir ; git ls-files --error-unmatch $basename >$null 2>&1")
        ) {
            # matched a tracked pathname
            my $matched;
            if (
                open(HANDLE, "-|",
                     "cd $dir ; git blame -e $basename 2> /dev/null")
            ) {
                while (my $line = <HANDLE>) {
                    chomp $line;
                    # Also remove CR from line-end
                    s/\015$//;

                    if ($line =~
                        m/^(\S+)[^(]+\(<([^>]+)>\s+([-0-9]+\s+[0-9:]+\s+[-+0-9]+)\s+([0-9]+)\) (.*)$/
                    ) {
                        my $commit = $1;
                        my $owner  = $2;
                        my $when   = $3;
                        my $text   = $5;

                        if ($self->[P4]) {
                            if (!exists($changelists{$commit})) {
                                if (
                                    open(GITLOG, '-|',
                                         "cd $dir ; git show -s $commit")
                                ) {
                                    while (my $l = <GITLOG>) {
                                        # p4sync puts special comment in commit log.
                                        #  pull the CL out of that.
                                        if ($l =~ /git-p4:.+change = ([0-9]+)/)
                                        {
                                            $changelists{$commit} = $1;
                                            $commit = $1;
                                            last;
                                        }
                                    }
                                } else {
                                    die("unable to execute 'git show -s $commit': $!"
                                    );
                                }
                                close(GITLOG) or die("unable to close");
                            } else {
                                $commit = $changelists{$commit};
                            }
                        }
                        # line owner filtering to canonical form
                        $owner =~ s/ dot /./g;
                        $owner =~ s/ at /\@/;
                        my $fullname = $owner;

                        if ($self->[DOMAIN]) {
                            ## strip domain part for internal users...
                            $owner =~ s/\@$self->[DOMAIN]//;
                            # replace everybody else with "External"
                            $owner =~ s/.*\@.*/External/;
                        }
                        # else leave domain in place

                        # Convert Git date/time to diffcov canonical format
                        # replace space between date and time with 'T'
                        $when =~ s/\s/T/;
                        # remove space between time and zone offset
                        $when =~ s/\s//;
                        # insert ':' between hour and minute digits of zone offset
                        $when =~ s/([0-9][0-9])$/:$1/;
                        # ';' is not a legal character in an email address -
                        #  so use it as a delimiter
                        push(@lines,
                             [$text, $owner, $fullname, $when, $commit]);
                        die("no uniform match")
                            if defined($matched) && !$matched;
                        $matched = 1;
                    } else {
                        push(@lines, [$line, "NONE", undef, "NONE", "NONE"]);
                        die("no uniform match")
                            if defined($matched) && $matched;
                        $matched = 0;
                    }
                }
                close(HANDLE) or die("unable to close git blame pipe: $!\n");
                $status = $?;
                #if (0 != $?) {
                #    $? & 0x7F &
                #        die("git blame died from signal ", ($? & 0x7F), "\n");
                #    die("git blame exited with error ", ($? >> 8), "\n");
                #}
                return ($status, \@lines);
            }
        }
    }

    # fallthrough from error conditions
    not_in_repo($pathname, \@lines);
    return ($status, \@lines);
}

1;