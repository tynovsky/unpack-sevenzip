package Unpack::SevenZip;

use strict;
use warnings;

use Carp;
use File::Basename qw(basename);
use IPC::Open3;
use IO::Handle;
use IO::Select;

our $VERSION = "0.02";

# per-file errors reported by 7-Zip >= 15 (and p7zip >= 15), e.g.
#   ERROR: CRC Failed : path
#   ERROR: Data Error in encrypted file. Wrong password? : path
my $ERROR_RE = qr/^ERROR: ((?:CRC Failed|Data Error|Unexpected end of data|Unsupported Method|Headers Error)[^:]*?) : (.*?)\s*$/;
# the same errors reported by older p7zip, e.g.
#   Extracting  path     CRC Failed
my $OLD_ERROR_RE = qr/^Extracting\s+(.*?)\s+(?:CRC Failed|Data Error|Unsupported Method)/;

sub new {
    my ($class, $args) = @_;

    my $self = bless { %{ $args // {} } }, $class;
    $self->{sevenzip} //= '7z';

    my $output = eval {
        my ($pid, $out, $err, $stdin) = $self->run_7zip('--help');
        $stdin->close();
        my ($stdout) = _read_all($out, $err);
        waitpid($pid, 0);
        $stdout;
    } // '';
    croak "Program '$self->{sevenzip}' doesn't seem to be 7zip"
        if $output !~ /Igor Pavlov/ || $output !~ /7-Zip/;

    return $self;
}

# Runs 7z without a shell, so file names and switches may contain any
# characters. Returns the pid and the stdout, stderr and stdin handles.
sub run_7zip {
    my ($self, $command, $archive_name, $switches, $files, $stdin) = @_;

    my @cmd = (
        $self->{sevenzip},
        (defined $command && length $command ? $command : ()),
        @{ $switches // [] },
    );
    if (defined $archive_name && length $archive_name) {
        # '--' stops switch parsing: an archive name may start with '-'
        push @cmd, '--', $archive_name, @{ $files // [] };
    }

    my ($out, $err) = (IO::Handle->new, IO::Handle->new);
    $stdin //= IO::Handle->new;
    my $pid = open3 $stdin, $out, $err, @cmd;
    binmode $out;

    return ($pid, $out, $err, $stdin)
}

sub info {
    my ($self, $filename, $params) = @_;

    my @params = @{ $params // [] };
    push @params, '-y'   if ! grep /^-y/, @params;
    push @params, '-slt' if ! grep /^-slt/, @params;
    # always use (at least) empty password, otherwise 7z waits for input
    push @params, '-p'   if ! grep /^-p/, @params;

    my ($pid, $out, $err, $stdin) = $self->run_7zip('l', $filename, \@params);
    $stdin->close();
    my ($content) = _read_all($out, $err);
    waitpid( $pid, 0 );
    $self->{last_exit_code} = $? >> 8;

    my ($file_list_started, $info_started, @files, $info);
    my $file = {};
    for my $line (split(/\r?\n/, $content), '') {
        $file_list_started ||= $line =~ /^----------$/;
        $info_started      ||= $line =~ /^--$/;
        next if $line =~ /^-+$/;

        if ($file_list_started) {
            if ($line eq '') { # empty lines separate the files
                push @files, $file if %$file;
                $file = {};
                next
            }
            my ($key, $value) = $line =~ /^(.*?) = (.*)$/ or next;
            $key = lc $key;
            if (grep { $_ eq $key } qw(path size folder)) {
                $file->{$key} = $value;
            }
        }
        elsif ($info_started) {
            if (my ($key, $value) = $line =~ /^(.*?) = (.*)$/) {
                $info->{lc $key} = $value;
            }
        }
    }

    for my $file (@files) {
        # unknown size (e.g. bzip2)
        delete $file->{size} if defined $file->{size} && $file->{size} !~ /^\d+$/;
        # compressed single file without a name (e.g. bzip2): 7z uses the
        # archive name without the extension
        if (! defined $file->{path} || $file->{path} eq '') {
            (my $path = basename($filename)) =~ s/\.[^.]*$//;
            $file->{path} = $path;
        }
    }

    return (\@files, $info)
}

sub extract {
    my ($self, $filename, $save, $params, $list, $passwords) = @_;

    my @params = @{ $params // [] };
    my @password_params = grep /^-p/, @params;

    # list the archive with the first password given
    $list //= ($self->info($filename, [ @password_params ? $password_params[0] : () ]))[0];
    $list = [ grep { !exists $_->{folder} || $_->{folder} ne '+' } @$list ];

    my @passwords = @{ $passwords // [] };
    push @passwords, map { substr $_, 2 } @password_params;
    # always use (at least) empty password. otherwise it hangs when the archive
    # is password protected (waits for user input)
    if (!grep { $_ eq '' } @passwords) {
        push @passwords, '';
    }

    @params = grep { !/^-p/ } @params;
    push @params, '-y'  if !grep /^-y/,  @params;
    push @params, '-so' if !grep /^-so/, @params;

    while (defined(my $password = shift @passwords)) {
        my ($pid, $out, $err, $stdin) = $self->run_7zip(
            'x', $filename, [ @params, "-p$password" ]);
        $stdin->close();
        my ($extracted, $corrupted, $unsaved)
            = $self->process_7zip_out( $out, $err, $stdin, $list, $save);
        waitpid( $pid, 0 );
        $self->{last_exit_code} = $? >> 8;
        # return if at least something succeeded or if we tried all passwords
        if (@$extracted || !@passwords) {
            return ($extracted, $corrupted, $unsaved);
        }
    }
}

sub process_7zip_out {
    my ($self, $out, $err, $stdin, $list, $save_fn) = @_;

    my $reader = IO::Select->new($err, $out);

    my @list = @$list;
    my $file = shift @list;
    my $contents = '';
    my $error_content = '';
    my @extracted_files;
    my @corrupted_paths;

    while ( my @ready = $reader->can_read() ) {
        foreach my $fh (@ready) {
            my $data;
            my $read_bytes = sysread $fh, $data, 65536;
            if (! $read_bytes) { # EOF or error
                $reader->remove($fh);
                $fh->close();
                next;
            }
            if ($fh == $err) {
                $error_content .= $data;
                next;
            }

            $contents .= $data;
            # save each file as soon as all its data are read; a file of
            # unknown size gets the rest of the output
            while ($file && defined $file->{size}
                && length($contents) >= $file->{size}
            ) {
                push @extracted_files, $save_fn->(
                    substr($contents, 0, $file->{size}, q()),
                    $file,
                );
                $file = shift @list;
            }
        }
    }
    $stdin->close() if $stdin && $stdin->opened;

    if ($file && ! defined $file->{size}) {
        push @extracted_files, $save_fn->($contents, $file);
        $contents = '';
        $file = shift @list;
    }
    elsif ($file && length $contents) {
        # output ended in the middle of a file
        push @corrupted_paths, $file->{path};
        $contents = '';
        $file = shift @list;
    }
    if (length $contents) {
        carp sprintf 'Unpack::SevenZip: %d bytes of unexpected output', length $contents;
    }

    for my $line (split /\r?\n/, $error_content) {
        if ($line =~ $ERROR_RE) {
            push @corrupted_paths, $2;
        }
        elsif ($line =~ $OLD_ERROR_RE) {
            push @corrupted_paths, $1;
        }
    }
    my %seen;
    @corrupted_paths = grep { !$seen{$_}++ } @corrupted_paths;

    my @unsaved = grep { defined } ($file, @list);
    carp 'Unpack::SevenZip: unsaved files: ', join ', ', map { $_->{path} } @unsaved
        if @unsaved && $self->{verbose};

    return \@extracted_files, \@corrupted_paths, \@unsaved
}

# read stdout and stderr of a process until both are closed
sub _read_all {
    my ($out, $err) = @_;

    my %content = ($out => '', $err => '');
    my $reader = IO::Select->new($out, $err);
    while (my @ready = $reader->can_read()) {
        for my $fh (@ready) {
            my $read_bytes = sysread $fh, my $data, 65536;
            if (! $read_bytes) {
                $reader->remove($fh);
                $fh->close();
                next;
            }
            $content{$fh} .= $data;
        }
    }

    return ($content{$out}, $content{$err});
}

1;
__END__

=encoding utf-8

=head1 NAME

Unpack::SevenZip - p7zip wrapper

=head1 SYNOPSIS

    use Unpack::SevenZip;

    my $unpacker = Unpack::SevenZip->new();   # or ->new({ sevenzip => '/usr/bin/7z' })

    my ($files, $info) = $unpacker->info('archive.7z');
    # $files: [ { path => 'a.txt', size => 42 }, ... ]

    my ($extracted, $corrupted, $unsaved) = $unpacker->extract(
        'archive.7z',
        sub {
            my ($contents, $file) = @_;
            # save $contents of $file->{path} somewhere
            return $saved_name;
        },
        ['-pPASSWORD'],
    );

=head1 DESCRIPTION

Unpack::SevenZip is a wrapper over p7zip tool. It allows you to define
a function for saving extracted files. The archive gets extracted and the user-defined
function (which gets the file data blob and the filename) is called for each
file extracted from the archive.

7z is executed directly (without a shell), so archive names and switches
may contain any characters. Array references passed to the methods are
never modified.

=head1 METHODS

=head2 new(\%args)

Dies if C<sevenzip> (default C<7z>) is not a 7-Zip binary. Set C<verbose>
to get warnings about files which were listed but not extracted.

=head2 info($archive, \@switches)

Returns an ARRAY reference of the files in the archive (hashes with keys
C<path>, C<size> and C<folder>; C<size> is missing when it is unknown) and
a HASH reference with information about the archive.

=head2 extract($archive, $save, \@switches, $list, \@passwords)

Calls C<< $save->($contents, $file) >> for each extracted file, where
C<$file> is an item of C<$list> (by default the result of C<info>). All
passwords (from C<\@passwords> and C<-p> switches, and the empty password)
are tried until something is extracted. Returns ARRAY references of the
values returned by C<$save>, of the paths of corrupted files and of the
files from C<$list> which were not extracted. The exit code of 7z is
stored in C<< $unpacker->{last_exit_code} >>.

=head2 run_7zip($command, $archive, \@switches, \@files)

Starts 7z and returns its pid and its stdout, stderr and stdin handles.

=head1 LICENSE

Copyright (C) Týnovský Miroslav.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 AUTHOR

Týnovský Miroslav E<lt>tynovsky@seznam.czE<gt>

=cut
