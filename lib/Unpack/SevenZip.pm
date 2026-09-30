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

=for stopwords rar xz iso sevenzip stdin

=head1 NAME

Unpack::SevenZip - list and extract archives with 7-Zip, into memory

=head1 SYNOPSIS

    use Unpack::SevenZip;

    my $unpacker = Unpack::SevenZip->new();   # or ->new({ sevenzip => '/usr/bin/7z' })

    my ($files, $info) = $unpacker->info('archive.7z');
    # $files: [ { path => 'a.txt', size => 42 }, ... ]
    # $info:  { type => '7z', method => 'LZMA2:24', solid => '+', ... }

    my ($extracted, $corrupted, $unsaved) = $unpacker->extract(
        'archive.7z',
        sub {
            my ($contents, $file) = @_;
            # do something with the content of $file->{path}
            return $file->{path};
        },
        ['-pPASSWORD'],
    );

=head1 DESCRIPTION

Unpack::SevenZip runs the 7-Zip command line program and extracts archives
of any format it can read (zip, 7z, rar, tar, gzip, bzip2, xz, iso, cab,
...) into memory: for each file in the archive a callback gets the content
of the file. Nothing is written to the disk.

It works by running C<7z x -so>, which writes the contents of all the files
to its standard output, one after another, and splitting the output into
files by their sizes from the list of files in the archive (C<7z l>).

7-Zip is executed directly (without a shell), so archive names and
switches may contain any characters. ARRAY references passed to the
methods are never modified. Nothing is printed to STDOUT.

L<Unpack::Custom> builds on this module and lets you define what happens
before, during and after extracting, including recursive extraction.

=head1 METHODS

=head2 new(\%args)

Arguments (all optional):

=over

=item sevenzip

Path to the 7-Zip binary (default C<7z>).

=item verbose

Warn about files which were listed but not extracted.

=back

Dies if C<sevenzip> can't be run or is not 7-Zip.

=head2 info($archive, \@switches)

Lists the archive. Returns

=over

=item *

an ARRAY reference of the files in the archive, in the order they are
stored: HASH references with the keys C<path>, C<size> (missing when 7-Zip
does not know it, e.g. for C<bzip2>) and C<folder> (C<+> for directories, if
the format has it). A file without a name (e.g. in C<bzip2>) gets the name of
the archive without its extension, as with C<7z x>.

=item *

a HASH reference with information about the archive (C<type>, C<method>,
C<solid>, C<physical size>, ...; the lowercased keys printed by
C<7z l -slt>), undefined when the file is not an archive.

=back

The list is empty when the file is not an archive 7-Zip can open (or it
has encrypted headers and no or a wrong password was given). Pass a
password switch, e.g. C<['-pPASSWORD']>, to list archives with encrypted
headers.

=head2 extract($archive, $save, \@switches, $list, \@passwords)

Extracts the archive and calls C<< $save->($contents, $file) >> for each
file in it (directories are skipped). C<$contents> is the whole content of
the file as a byte string, C<$file> is an item of C<$list>.

=over

=item \@switches

Additional 7-Zip switches, e.g. C<['-x!*.log']>. C<-p> switches are used
as passwords.

=item $list

The files 7-Zip extracts, as returned by C<info> (the default, so the
archive is listed first). It must contain exactly the files 7-Zip
extracts, in the same order, otherwise the output is split incorrectly:
when you exclude files by switches, remove them from the list too.

=item \@passwords

Passwords to try. The passwords from the C<-p> switches and the empty
password are tried too, in this order, until something is extracted.

=back

Returns three ARRAY references:

=over

=item *

the values returned by C<$save>,

=item *

the paths of the files 7-Zip reported as corrupted (CRC error, data error,
wrong password, ...) or whose content was cut off; their (possibly damaged)
content may have been passed to C<$save>,

=item *

the items of C<$list> which were not extracted.

=back

The exit code of 7-Zip is stored in C<< $unpacker->{last_exit_code} >>
(also by C<info>).

=head2 run_7zip($command, $archive, \@switches, \@files)

Starts 7-Zip with the given command (e.g. C<l>, C<x>) and returns its pid
and its stdout, stderr and stdin handles; used by C<info> and C<extract>.
Read both output handles and call C<waitpid> on the pid.

=head1 REQUIREMENTS

The 7-Zip command line program C<7z>, e.g. the C<7zip> package (or the
older C<p7zip-full>) on Debian and Ubuntu; RAR archives need the C<7zip-rar>
package there. Both 7-Zip 15 and newer and the older p7zip are supported.

=head1 LIMITATIONS

Each extracted file is kept in memory until it is passed to C<$save>, so
the largest file in an archive has to fit into memory.

=head1 SEE ALSO

L<Unpack::Custom>

=head1 LICENSE

Copyright (C) Týnovský Miroslav.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 AUTHOR

Týnovský Miroslav E<lt>tynovsky@seznam.czE<gt>

=cut
