package Unpack::SevenZip;

use v5.16;
use strict;
use warnings;
use Data::Dumper;

use IPC::Open3;
use IO::Handle;

our $VERSION = "0.01";

my $sevenzip = '/home/tynovsky/p7zip_9.20.1/bin/7z';

sub new {
    my ($class, $args) = @_;
    $args //= {};

    return bless $args, $class;
}

sub run_7zip {
    my ($self, $command, $archive_name, $switches, $files, $stdin) = @_;
    $_ //= [] for $switches, $files;
    $_ //= '' for $command, $archive_name;

    my ($out, $err) = (IO::Handle->new, IO::Handle->new);
    my $cmd = "$sevenzip $command @$switches '$archive_name' @$files";
    #print STDERR "$cmd\n";
    my $pid = open3 $stdin, $out, $err, $cmd;

    return ($pid, $out, $err)
}

sub info {
    my ($self, $filename) = @_;
    my ($pid, $out) = $self->run_7zip('l', $filename, ['-slt']);

    my ($file_list_started, $info_started, @files, $file, $info);
    while (my $line = <$out>) {
        $file_list_started ||= $line =~ /^----------$/;
        $info_started      ||= $line =~ /^--$/;
        next if $line =~ /^-+$/;

        if ($file_list_started) {
            if ($line =~ /^$/) { # empty lines separate the files
                push @files, $file;
                $file = {};
                next
            }
            my ($key, $value) = $line =~ /(.*?) = (.*)/;
            if (grep $_ eq lc($key), qw(path size)) {
                $file->{lc $key} = $value;
            }
        }
        elsif ($info_started) {
            if( my ($key, $value) = $line =~ /(.*?) = (.*)/ ) {
                $info->{lc $key} = $value;
            }
        }
        else {
            next
        }
    }

    return (\@files, $info);
}

sub extract {
    my ($self, $filename, $want_extract, $save, $params, $list) = @_;

    return [] if ! $want_extract->($filename);

    $list   //= ($self->info($filename))[0];
    $params //= [];
    push @$params, '-so';

    my ($pid, $out, $err) = $self->run_7zip('x', $filename, $params);
    return $self->process_7zip_out( $out, $err, $list, $save);
}

sub process_7zip_out {
    my ($self, $out, $err, $list, $save_fn) = @_;

    my $success = 0;
    my $szip_out;
    my $reader = IO::Select->new($err, $out);

    my $file = shift @$list;
    my $contents;
    my @extracted_files;
    while ( my @ready = $reader->can_read() ) {
        foreach my $fh (@ready) {
            if (defined fileno($out) && fileno($fh) == fileno($out)) {
                use bytes;
                my $read_anything = 0;
                my $data;
                while (my $read_bytes = $fh->read($data, 4096)) {
                    $contents .= $data;
                    if (length($contents) >= $file->{size}) {
                        push @extracted_files, $save_fn->(
                            substr($contents, 0, $file->{size}),
                            $file,
                        );
                        $contents = substr($contents, $file->{size});
                        $file = shift @$list;
                    }
                    $read_anything = 1;
                }
                if (!$read_anything) {
                    $reader->remove($fh);
                    $fh->close();
                    next
                }
            }
            elsif (defined fileno($err) && fileno($fh) == fileno($err)) {
                my $line = <$fh>;
                if (!defined $line) {
                    $reader->remove($fh);
                    $fh->close();
                    next
                }
                $success = 1 if $line =~ /^Everything is Ok/;
                $szip_out .= $line;
            }
        }
    }
    if ($contents) {
        push @extracted_files, $save_fn->($contents, $file);
    }

    if (! $success ) {
        print STDERR $szip_out;
        die "7zip failed to extract.\n";
    }

    return \@extracted_files;
}

1;
__END__

=encoding utf-8

=head1 NAME

Unpack::SevenZip - It's new $module

=head1 SYNOPSIS

    use Unpack::SevenZip;

=head1 DESCRIPTION

Unpack::SevenZip is a wrapper over p7zip tool. It allows you to define
a function for saving files. The archive gets extracted and the user-defined
function (which gets the file data blob and the filename) is called for each
file extracted from the archive.

=head1 LICENSE

Copyright (C) Týnovský Miroslav.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 AUTHOR

Týnovský Miroslav E<lt>tynovsky@avast.comE<gt>

=cut
