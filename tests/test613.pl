#!/usr/bin/env perl
#***************************************************************************
#                                  _   _ ____  _
#  Project                     ___| | | |  _ \| |
#                             / __| | | | |_) | |
#                            | (__| |_| |  _ <| |___
#                             \___|\___/|_| \_\_____|
#
# Copyright (C) Daniel Stenberg, <daniel@haxx.se>, et al.
#
# This software is licensed as described in the file COPYING, which
# you should have received as part of this distribution. The terms
# are also available at https://curl.se/docs/copyright.html.
#
# You may opt to use, copy, modify, merge, publish, distribute and/or sell
# copies of the Software, and permit persons to whom the Software is
# furnished to do so, under the terms of the COPYING file.
#
# This software is distributed on an "AS IS" basis, WITHOUT WARRANTY OF ANY
# KIND, either express or implied.
#
# SPDX-License-Identifier: curl
#
###########################################################################
use strict;
use warnings;

# Prepare a directory with known files and clean up afterwards
use Time::Local;

if($#ARGV < 1) {
    print "Usage: $0 prepare|postprocess directory [logfile]\n";
    print "       $0 prepare-many directory count\n";
    print "       $0 postprocess-many directory count logfile\n";
    exit 1;
}

# name of the many-files entry number $_[0]
sub manyname {
    return sprintf("f%05d", $_[0]);
}

# <precheck> expects an error message on stdout
sub errout {
    print $_[0] . "\n";
    exit 1;
}

if($ARGV[0] eq "prepare") {
    my $dirname = $ARGV[1];
    mkdir $dirname or errout "$!";
    chdir $dirname;

    # Create the files in alphabetical order, to increase the chances
    # of receiving a consistent set of directory contents regardless
    # of whether the server alphabetizes the results or not.
    mkdir "asubdir" or errout "$!";
    chmod 0777, "asubdir";

    open(FILE, ">", 'plainfile.txt') or errout "$!";
    binmode FILE;
    print FILE "Test file to support curl test suite\n";
    close(FILE);
    # The mtime is specifically chosen to be an even number so that it can be
    # represented exactly on a FAT file system.
    utime time, timegm(0, 0, 12, 1, 0, 100), "plainfile.txt";
    chmod 0666, "plainfile.txt";

    open(FILE, ">", 'emptyfile.txt') or errout "$!";
    binmode FILE;
    close(FILE);
    # The mtime is specifically chosen to be an even number so that it can be
    # represented exactly on a FAT file system.
    utime time, timegm(0, 0, 12, 1, 0, 100), "emptyfile.txt";
    chmod 0666, "emptyfile.txt";

    open(FILE, ">", 'rofile.txt') or errout "$!";
    binmode FILE;
    print FILE "Read-only test file to support curl test suite\n";
    close(FILE);
    # The mtime is specifically chosen to be an even number so that it can be
    # represented exactly on a FAT file system.
    utime time, timegm(0, 0, 12, 31, 11, 100), "rofile.txt";
    chmod 0444, "rofile.txt";
    if($^O eq 'cygwin') {
      system('chattr', ('+r', 'rofile.txt'));
    }

    exit 0;
}
elsif($ARGV[0] eq "postprocess") {
    my $dirname = $ARGV[1];

    # Clean up the test directory
    if($^O eq 'cygwin') {
      system('chattr', ('-r', "$dirname/rofile.txt"));
    }
    chmod 0666, "$dirname/rofile.txt";
    unlink "$dirname/rofile.txt";
    unlink "$dirname/emptyfile.txt";
    unlink "$dirname/plainfile.txt";
    rmdir "$dirname/asubdir";

    rmdir $dirname or die "$!";

    if($#ARGV >= 3) {  # Verify mtime if requested
        my $checkfile = $ARGV[2];
        my $expected_mtime = int($ARGV[3]);
        my $mtime = (stat($checkfile))[9];
        exit ($mtime != $expected_mtime);
    }

    my $logfile = $ARGV[2];
    if($logfile && -s $logfile) {
        # Process the directory file to remove all information that
        # could be inconsistent from one test run to the next (e.g.
        # file date) or may be unsupported on some platforms (e.g.
        # Windows). Also, since 7.17.0, the sftp directory listing
        # format can be dependent on the server (with a recent
        # enough version of libssh2) so this script must also
        # canonicalize the format.  Here are examples of the general
        # format supported:
        # -r--r--r--   12 ausername grp            47 Dec 31  2000 rofile.txt
        # -r--r--r--   1  1234  4321         47 Dec 31  2000 rofile.txt
        # The "canonical" format is similar to the first (which is
        # the one generated on a typical Linux installation):
        # -r-?r-?r-?   12 U         U              47 Dec 31  2000 rofile.txt

        my @canondir;
        open(IN, "<", $logfile) or die "$!";
        while(<IN>) {
            /^(.)(..).(..).(..).\s*(\S+)\s+\S+\s+\S+\s+(\S+)\s+(\S+\s+\S+\s+\S+)\s+(.*)$/;
            if($1 eq "d") {
                # Skip current and parent directory listing, because some SSH
                # servers (eg. OpenSSH for Windows) are not listing those
                if($8 eq "." || $8 eq "..") {
                    next;
                }
                # Erase all directory metadata except for the name, as it is not
                # consistent for across all test systems and file systems
                push @canondir, "d?????????    N U         U               N ???  N NN:NN $8\n";
            }
            elsif($1 eq "-") {
                # Ignore group and other permissions, because these may vary on
                # some systems (e.g. on Windows)
                # Erase user and group names, as they are not consistent across
                # all test systems
                my $line = sprintf("%s%s???????%5d U         U %15d %s %s\n", $1, $2, $5, $6, $7, $8);
                push @canondir, $line;
            }
            else {
                # Unexpected format; pass it through and let the test fail
                push @canondir, $_;
            }
        }
        close(IN);

        @canondir = sort {substr($a, 57) cmp substr($b, 57)} @canondir;
        my $newfile = $logfile . ".new";
        open(OUT, ">", $newfile) or die "$!";
        print OUT join('', @canondir);
        close(OUT);

        unlink $logfile;
        rename $newfile, $logfile;
    }

    exit 0;
}
elsif($ARGV[0] eq "prepare-many") {
    # A directory with enough empty files to need more than one round of
    # the SFTP directory listing state machine
    my ($dirname, $count) = @ARGV[1..2];
    mkdir $dirname or errout "$!";
    for my $i (0 .. $count - 1) {
        my $name = "$dirname/" . manyname($i);
        open(FILE, ">", $name) or errout "$!";
        close(FILE);
    }
    exit 0;
}
elsif($ARGV[0] eq "postprocess-many") {
    # Check that the listing in the logfile names every file exactly once,
    # in either the names-only or the long format, then replace the logfile
    # with a one-line verdict that the test's datacheck compares.
    my ($dirname, $count, $logfile) = @ARGV[1..3];

    for my $i (0 .. $count - 1) {
        unlink "$dirname/" . manyname($i);
    }
    rmdir $dirname or die "$!";

    my @names;
    open(IN, "<", $logfile) or die "$!";
    while(<IN>) {
        chomp;
        s/\r$//;
        # the name is the last word on the line in both formats
        my $name = (split(/\s+/, $_))[-1];
        next if(!defined($name) || $name eq "." || $name eq "..");
        push @names, $name;
    }
    close(IN);

    my @want = map { manyname($_) } (0 .. $count - 1);
    my $got = join(",", sort @names);
    my $verdict = ($got eq join(",", @want)) ?
        "$count entries listed\n" :
        sprintf("listing mismatch: %d entries, %d unique\n",
                scalar(@names), scalar(keys %{{ map { $_ => 1 } @names }}));

    open(OUT, ">", $logfile) or die "$!";
    print OUT $verdict;
    close(OUT);
    exit 0;
}
print "Unsupported command $ARGV[0]\n";
exit 1;
