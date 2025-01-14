package Devscripts::MkOrigtargz;

use strict;
use Cwd 'abs_path';
use Devscripts::Compression qw/
  compression_guess_from_file
  compression_get_file_extension
  compression_get_cmdline_compress
  compression_get_cmdline_decompress
  /;
use Devscripts::MkOrigtargz::Config;
use Devscripts::Output;
use Devscripts::Uscan::Output;
use Devscripts::Utils;
use Dpkg::Changelog::Debian;
use Dpkg::Control::Hash;
use Dpkg::IPC;
use Dpkg::Version;
use File::Copy;
use File::Spec;
use File::Temp qw/tempdir/;
use Moo;

has config => (
    is      => 'rw',
    default => sub {
        Devscripts::MkOrigtargz::Config->new->parse;
    },
);

has exclude_globs => (
    is      => 'rw',
    lazy    => 1,
    default => sub { $_[0]->config->exclude_file },
);

has include_globs => (
    is      => 'rw',
    lazy    => 1,
    default => sub { $_[0]->config->include_file },
);

has status        => (is => 'rw', default => sub { 0 });
has destfile_nice => (is => 'rw');

our $found_comp;

sub do {
    my ($self) = @_;
    $self->parse_copyrights or $self->make_orig_targz;
    return $self->status;
}

sub make_orig_targz {
    my ($self) = @_;

    # Now we know what the final filename will be
    my $destfilebase = sprintf "%s_%s.%s.tar", $self->config->package,
      $self->config->version, $self->config->orig;
    my $destfiletar = sprintf "%s/%s", $self->config->directory, $destfilebase;
    my $destext
      = $self->config->compression eq 'default'
      ? 'default'
      : compression_get_file_extension($self->config->compression);
    my $destfile;

    # $upstream_tar is $upstream, unless the latter was a zip file.
    my $upstream_tar = $self->config->upstream;

    # Remember this for the final report
    my $zipfile_deleted = 0;

    # If the file is a zipfile, we need to create a tarfile from it.
    if ($self->config->upstream_type eq 'zip') {
        $destfile = $self->fix_dest_file($destfiletar);
        if ($self->config->signature) {
            $self->config->signature(4);    # repack upstream file
        }

        my $tempdir = tempdir("uscanXXXX", TMPDIR => 1, CLEANUP => 1);
        # Parent of the target directory should be under our control
        $tempdir .= '/repack';
        my @cmd;
        if ($self->config->upstream_comp eq 'xpi') {
            @cmd = ('xpi-unpack', $upstream_tar, $tempdir);
            unless (ds_exec_no_fail(@cmd) >> 8 == 0) {
                ds_die("Repacking from xpi failed (could not xpi-unpack)\n");
                return $self->status(1);
            }
        } else {
            unless (mkdir $tempdir) {
                ds_die("Unable to mkdir($tempdir): $!\n");
                return $self->status(1);
            }
            @cmd = ('unzip', '-q');
            push @cmd, split ' ', $self->config->unzipopt
              if defined $self->config->unzipopt;
            push @cmd, ('-d', $tempdir, $upstream_tar);
            unless (ds_exec_no_fail(@cmd) >> 8 == 0) {
                ds_die("Repacking from zip or jar failed (could not unzip)\n");
                return $self->status(1);
            }
        }

        # Figure out the top-level contents of the tarball.
        # If we'd pass "." to tar we'd get the same contents, but the filenames
        # would start with ./, which is confusing later.
        # This should also be more reliable than, say, changing directories and
        # globbing.
        unless (opendir(TMPDIR, $tempdir)) {
            ds_die("Can't open $tempdir $!\n");
            return $self->status(1);
        }
        my @files = grep { $_ ne "." && $_ ne ".." } readdir(TMPDIR);
        close TMPDIR;

        # tar it all up
        spawn(
            exec => [
                'tar',          '--owner=root',
                '--group=root', '--mode=a+rX',
                '--create',     '--file',
                "$destfiletar", '--directory',
                $tempdir,       @files
            ],
            wait_child => 1
        );
        unless (-e "$destfiletar") {
            ds_die(
"Repacking from zip or jar to tar.$destext failed (could not create tarball)\n"
            );
            return $self->status(1);
        }
        eval {
            compress_archive($destfiletar, $destfile,
                $self->config->compression);
        };
        if ($@) {
            ds_die($@);
            return $self->status(1);
        }

        # rename means the user did not want this file to exist afterwards
        if ($self->config->mode eq "rename") {
            unlink $upstream_tar;
            $zipfile_deleted++;
        }

        $self->config->mode('repack');
        $upstream_tar = $destfile;
    } elsif (compression_guess_from_file($upstream_tar) =~ /^zstd?$/) {
        $self->config->force_repack(1);
    }

    # From now on, $upstream_tar is guaranteed to be a compressed tarball. It
    # is always a full (possibly relative) path, and distinct from $destfile.

    # Find out if we have to repack
    my $do_repack = 0;
    if ($self->config->repack) {
        my $comp = compression_guess_from_file($upstream_tar);
        unless ($comp) {
            ds_die("Cannot determine compression method of $upstream_tar");
            return $self->status(1);
        }
        $do_repack = (
            $comp eq 'tar'
              or (  $self->config->compression ne 'default'
                and $comp ne $self->config->compression)
              or (  $self->config->compression eq 'default'
                and $comp ne
                &Devscripts::MkOrigtargz::Config::default_compression));
    }

    # Removing files
    my $deletecount = 0;
    my @to_delete;

    if (@{ $self->exclude_globs }) {
        my @files;
        my $files;
        spawn(
            exec       => ['tar', '-t', '-a', '-f', $upstream_tar],
            to_string  => \$files,
            wait_child => 1
        );
        @files = split /^/, $files;
        chomp @files;

        my %delete;
        # find out what to delete
        my @exclude_info;
        eval {
            @exclude_info
              = map { { glob => $_, used => 0, regex => glob_to_regex($_) } }
              @{ $self->exclude_globs };
        };
        if ($@) {
            ds_die($@);
            return $self->status(1);
        }
        for my $filename (sort @files) {
            my $last_match;
            for my $info (@exclude_info) {
                if (
                    $filename
                    =~ m@^(?:[^/]*/)? # Possible leading directory, ignore it
				(?:$info->{regex}) # User pattern
				(?:/.*)?$          # Possible trailing / for a directory
			      @x
                ) {
                    if (!$last_match) {
                        # if the current entry is a directory, check if it
                        # matches any exclude-ignored glob
                        my $ignore_this_exclude = 0;
                        for my $ignore_exclude (@{ $self->include_globs }) {
                            my $ignore_exclude_regex
                              = glob_to_regex($ignore_exclude);

                            if ($filename =~ $ignore_exclude_regex) {
                                $ignore_this_exclude = 1;
                                last;
                            }
                            if (   $filename =~ m,/$,
                                && $ignore_exclude =~ $info->{regex}) {
                                $ignore_this_exclude = 1;
                                last;
                            }
                        }
                        next if $ignore_this_exclude;
                        $delete{$filename} = 1;
                    }
                    $last_match = $info;
                }
            }
            if (defined $last_match) {
                $last_match->{used} = 1;
            }
        }

        for my $info (@exclude_info) {
            if (!$info->{used}) {
                ds_warn
"No files matched excluded pattern as the last matching glob: $info->{glob}\n";
            }
        }

        # ensure files are mentioned before the directory they live in
        # (otherwise tar complains)
        @to_delete = sort { $b cmp $a } keys %delete;

        $deletecount = scalar(@to_delete);
    }

    if ($deletecount or $self->config->force_repack) {
        $destfilebase = sprintf "%s_%s%s.%s.tar", $self->config->package,
          $self->config->version, $self->config->repack_suffix,
          $self->config->orig;
        $destfiletar = sprintf "%s/%s", $self->config->directory,
          $destfilebase;
        $destfile = $self->fix_dest_file($destfiletar);

        # Zip -> tar process already created $destfile, so need to rename it
        if ($self->config->upstream_type eq 'zip') {
            move($upstream_tar, $destfile);
            $upstream_tar = $destfile;
        }
    }

    # Actually do the unpack, remove, pack cycle
    if ($do_repack || $deletecount || $self->config->force_repack) {
        $destfile ||= $self->fix_dest_file($destfiletar);
        if ($self->config->signature) {
            $self->config->signature(4);    # repack upstream file
        }
        if ($self->config->upstream_comp) {
            eval { decompress_archive($upstream_tar, $destfiletar) };
            if ($@) {
                ds_die($@);
                return $self->status(1);
            }
        } else {
            copy $upstream_tar, $destfiletar;
        }
        unlink $upstream_tar if $self->config->mode eq "rename";
        # We have to use piping because --delete is broken otherwise, as
        # documented at
        # https://www.gnu.org/software/tar/manual/html_node/delete.html
        if (@to_delete) {
            # ARG_MAX: max number of bytes exec() can handle
            my $arg_max;
            spawn(
                exec       => ['getconf', 'ARG_MAX'],
                to_string  => \$arg_max,
                wait_child => 1
            );
            # Under Hurd `getconf` above returns "undefined".
            # It's apparently unlimited (?), so we just use a arbitrary number.
            if ($arg_max =~ /\D/) { $arg_max = 131072; }
            # Usually NAME_MAX=255, but here we use 128 to be on the safe side.
            $arg_max = int($arg_max / 128);
            # We use this lame splice on a totally arbitrary $arg_max because
            # counting how many bytes there are in @to_delete is too
            # inefficient.
            while (my @next_n = splice @to_delete, 0, $arg_max) {
                spawn(
                    exec       => ['tar', '--delete', @next_n],
                    from_file  => $destfiletar,
                    to_file    => $destfiletar . ".tmp",
                    wait_child => 1
                ) if scalar(@next_n) > 0;
                move($destfiletar . ".tmp", $destfiletar);
            }
        }
        eval {
            compress_archive($destfiletar, $destfile,
                $self->config->compression);
        };
        if ($@) {
            ds_die $@;
            return $self->status(1);
        }

        # Symlink no longer makes sense
        $self->config->mode('repack');
        $upstream_tar = $destfile;
    } else {
        $destfile = $self->fix_dest_file($destfiletar,
            compression_guess_from_file($upstream_tar), 1);
    }

    # Final step: symlink, copy or rename for tarball.

    my $same_name = abs_path($destfile) eq abs_path($self->config->upstream);
    unless ($same_name) {
        if (    $self->config->mode ne "repack"
            and $upstream_tar ne $self->config->upstream) {
            ds_die "Assertion failed";
            return $self->status(1);
        }

        if ($self->config->mode eq "symlink") {
            my $rel
              = File::Spec->abs2rel($upstream_tar, $self->config->directory);
            symlink $rel, $destfile;
        } elsif ($self->config->mode eq "copy") {
            copy($upstream_tar, $destfile);
        } elsif ($self->config->mode eq "rename") {
            move($upstream_tar, $destfile);
        }
    }

    # Final step: symlink, copy or rename for signature file.

    my $destsigfile;
    if ($self->config->signature == 1) {
        $destsigfile = sprintf "%s.asc", $destfile;
    } elsif ($self->config->signature == 2) {
        $destsigfile = sprintf "%s.asc", $destfiletar;
    } elsif ($self->config->signature == 3) {
        # XXX FIXME XXX place holder
        $destsigfile = sprintf "%s.asc", $destfile;
    } else {
        # $self->config->signature == 0 or 4
        $destsigfile = "";
    }

    if ($self->config->signature == 1 or $self->config->signature == 2) {
        my $is_openpgp_ascii_armor = 0;
        my $fh_sig;
        unless (open($fh_sig, '<', $self->config->signature_file)) {
            ds_die "Cannot open $self->{config}->{signature_file}\n";
            return $self->status(1);
        }
        while (<$fh_sig>) {
            if (m/^-----BEGIN PGP /) {
                $is_openpgp_ascii_armor = 1;
                last;
            }
        }
        close($fh_sig);

        if (not $is_openpgp_ascii_armor) {
            my @enarmor
              = `gpg --no-options --output - --enarmor $self->{config}->{signature_file} 2>&1`;
            unless ($? == 0) {
                ds_die
"Failed to convert $self->{config}->{signature_file} to *.asc\n";
                return $self->status(1);
            }
            unless (open(DESTSIG, '>', $destsigfile)) {
                ds_die "Failed to open $destsigfile for write $!\n";
                return $self->status(1);
            }
            foreach my $line (@enarmor) {
                next if $line =~ m/^Version:/;
                next if $line =~ m/^Comment:/;
                $line =~ s/ARMORED FILE/SIGNATURE/;
                print DESTSIG $line;
            }
            unless (close(DESTSIG)) {
                ds_die
"Cannot write signature file $self->{config}->{signature_file}\n";
                return $self->status(1);
            }
        } else {
            if (abs_path($self->config->signature_file) ne
                abs_path($destsigfile)) {
                if ($self->config->mode eq "symlink") {
                    my $rel = File::Spec->abs2rel(
                        $self->config->signature_file,
                        $self->config->directory
                    );
                    symlink $rel, $destsigfile;
                } elsif ($self->config->mode eq "copy") {
                    copy($self->config->signature_file, $destsigfile);
                } elsif ($self->config->mode eq "rename") {
                    move($self->config->signature_file, $destsigfile);
                } else {
                    ds_die 'Strange mode="' . $self->config->mode . "\"\n";
                    return $self->status(1);
                }
            }
        }
    } elsif ($self->config->signature == 3) {
        uscan_msg_raw
"Skip adding upstream signature since upstream file has non-detached signature file.";
    } elsif ($self->config->signature == 4) {
        uscan_msg_raw
          "Skip adding upstream signature since upstream file is repacked.";
    }

    # Final check: Is the tarball usable

    # We are lazy and rely on Dpkg::IPC to report an error message
    # (spawn does not report back the error code).
    # We don't expect this to occur often anyways.
    my $ret = spawn(
        exec => ['tar', '--list', '--auto-compress', '--file', $destfile],
        wait_child => 1,
        to_file    => '/dev/null'
    );

    # Tell the user what we did

    my $upstream_nice = File::Spec->canonpath($self->config->upstream);
    my $destfile_nice = File::Spec->canonpath($destfile);
    $self->destfile_nice($destfile_nice);

    if ($same_name) {
        uscan_msg_raw "Leaving $destfile_nice where it is";
    } else {
        if (   $self->config->upstream_type eq 'zip'
            or $do_repack
            or $deletecount
            or $self->config->force_repack) {
            uscan_msg_raw
              "Successfully repacked $upstream_nice as $destfile_nice";
        } elsif ($self->config->mode eq "symlink") {
            uscan_msg_raw
              "Successfully symlinked $upstream_nice to $destfile_nice";
        } elsif ($self->config->mode eq "copy") {
            uscan_msg_raw
              "Successfully copied $upstream_nice to $destfile_nice";
        } elsif ($self->config->mode eq "rename") {
            uscan_msg_raw
              "Successfully renamed $upstream_nice to $destfile_nice";
        } else {
            ds_die 'Unknown mode ' . $self->config->mode;
            return $self->status(1);
        }
    }

    if ($deletecount) {
        uscan_msg_raw ", deleting ${deletecount} files from it";
    }
    if ($zipfile_deleted) {
        uscan_msg_raw ", and removed the original file";
    }
    print ".\n";
    return 0;
}

sub decompress_archive {
    my ($from_file, $to_file) = @_;
    my $comp = compression_guess_from_file($from_file);
    unless ($comp) {
        die("Cannot determine compression method of $from_file");
    }

    my @cmd = compression_get_cmdline_decompress($comp);
    spawn(
        exec       => \@cmd,
        from_file  => $from_file,
        to_file    => $to_file,
        wait_child => 1
    );
}

sub compress_archive {
    my ($from_file, $to_file, $comp) = @_;

    my @cmd = compression_get_cmdline_compress($comp);
    spawn(
        exec       => \@cmd,
        from_file  => $from_file,
        to_file    => $to_file,
        wait_child => 1
    );
    unlink $from_file;
}

# Adapted from Text::Glob::glob_to_regex_string
sub glob_to_regex {
    my ($glob) = @_;

    if ($glob =~ m@/$@) {
        ds_warn
          "Files-Excluded pattern ($glob) should not have a trailing /\n";
        chop($glob);
    }
    if ($glob =~ m/(?<!\\)(?:\\{2})*\\(?![\\*?])/) {
        die
"Invalid Files-Excluded pattern ($glob), \\ can only escape \\, *, or ? characters\n";
    }

    my ($regex, $escaping);
    for my $c ($glob =~ m/(.)/gs) {
        if (
               $c eq '.'
            || $c eq '('
            || $c eq ')'
            || $c eq '|'
            || $c eq '+'
            || $c eq '^'
            || $c eq '$'
            || $c eq '@'
            || $c eq '%'
            || $c eq '{'
            || $c eq '}'
            || $c eq '['
            || $c eq ']'
            ||

            # Escape '#' since we're using /x in the pattern match
            $c eq '#'
        ) {
            $regex .= "\\$c";
        } elsif ($c eq '*') {
            $regex .= $escaping ? "\\*" : ".*";
        } elsif ($c eq '?') {
            $regex .= $escaping ? "\\?" : ".";
        } elsif ($c eq "\\") {
            if ($escaping) {
                $regex .= "\\\\";
                $escaping = 0;
            } else {
                $escaping = 1;
            }
            next;
        } else {
            $regex .= $c;
            $escaping = 0;
        }
        $escaping = 0;
    }

    return $regex;
}

sub parse_copyrights {
    my ($self) = @_;
    for my $copyright_file (@{ $self->config->copyright_file }) {
        my $data = Dpkg::Control::Hash->new();
        my $okformat
          = qr'https?://www.debian.org/doc/packaging-manuals/copyright-format/[.\d]+';
        eval {
            $data->load($copyright_file);
            1;
        } or do {
            undef $data;
        };
        if (not -e $copyright_file) {
            ds_die "File $copyright_file not found.";
            return $self->status(1);
        } elsif ($data
            && defined $data->{format}
            && $data->{format} =~ m@^$okformat/?$@) {
            if ($data->{ $self->config->excludestanza }) {
                push(
                    @{ $self->exclude_globs },
                    grep { $_ }
                      split(/\s+/, $data->{ $self->config->excludestanza }));
            }
            if ($data->{ $self->config->includestanza }) {
                push(
                    @{ $self->include_globs },
                    grep { $_ }
                      split(/\s+/, $data->{ $self->config->includestanza }));
            }
        } else {
            if (open my $file, '<', $copyright_file) {
                while (my $line = <$file>) {
                    if ($line =~ m/\b$self->{config}->{excludestanza}.*:/i) {
                        ds_warn "The file $copyright_file mentions "
                          . $self->config->excludestanza
                          . ", but its "
                          . "format is not recognized. Specify Format: "
                          . "https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/ "
                          . "in order to remove files from the tarball with mk-origtargz.\n";
                        last;
                    }
                }
                close $file;
            } else {
                ds_die "Unable to read $copyright_file: $!\n";
                return $self->status(1);
            }
        }
    }
}

sub fix_dest_file {
    my ($self, $destfiletar, $comp, $force) = @_;
    if ($self->config->compression eq 'default' or $force) {
        $self->config->compression($comp
              || &Devscripts::MkOrigtargz::Config::default_compression);
    }
    $comp = compression_get_file_extension($self->config->compression);
    $found_comp ||= $self->config->compression;
    return sprintf "%s.%s", $destfiletar, $comp;
}

1;
