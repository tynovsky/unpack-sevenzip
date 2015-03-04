package Unpack::SevenZip;

use v5.16;
use strict;
use warnings;
use Data::Dumper;

use IPC::Open3;
use IO::Handle;
use IO::Select;

our $VERSION = "0.01";

sub new {
    my ($class, $args) = @_;
    $args //= { };
    $args->{sevenzip} //= '/usr/bin/7z';

    return bless $args, $class;
}

sub run_7zip {
    my ($self, $command, $archive_name, $switches, $files, $stdin) = @_;
    $_ //= [] for $switches, $files;
    $_ //= '' for $command, $archive_name;

    my ($out, $err) = (IO::Handle->new, IO::Handle->new);
    $stdin //= IO::Handle->new;
    my $cmd = "$self->{sevenzip} $command @$switches '$archive_name' @$files";
    # say STDERR $cmd;
    my $pid = open3 $stdin, $out, $err, $cmd;

    return ($pid, $out, $err, $stdin)
}

sub info {
    my ($self, $filename, $params) = @_;

    $params //= [];
    push @$params, '-y';
    push @$params, '-slt';
    push @$params, '-p' if !grep /^-p/, @$params;
    my ($pid, $out, $err, $stdin) = $self->run_7zip('l', $filename, $params);

    my ($file_list_started, $info_started, @files, $file, $info, $prev_content);
    my $reader = IO::Select->new($err, $out);
    my $content;
    while ( my @ready = $reader->can_read(1000) ) {
        foreach my $fh (@ready) {
            if (defined fileno($out) && defined fileno($fh) && fileno($fh) == fileno($out)) {
                my $data;
                my $read_bytes = $fh->sysread($data, 4096);
                $content .= $data;
                if ($read_bytes == 0) {
                    $reader->remove($fh);
                    $fh->close();
                }
            }

            if (defined fileno($err) && defined fileno($fh) && fileno($fh) == fileno($err)) {
                my $data;
                my $read_bytes = $fh->sysread($data, 4096);
                if ($read_bytes == 0) {
                    $reader->remove($fh);
                    $fh->close();
                }
            }
        }
    }

    $stdin->close();
    waitpid( $pid, 0 );

    for my $line (split(/\n/, $content), '') {
        $file_list_started ||= $line =~ /^----------$/;
        $info_started      ||= $line =~ /^--$/;
        next if $line =~ /^-+$/;

        if ($file_list_started) {
            if ($line =~ /^$/) { # empty lines separate the files
                push @files, $file;
                #print STDERR "pushed $file->{path}, size is ", scalar(@files), "\n";
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
    #print "files", Dumper \@files;
    #print "info", Dumper $info;

    return (\@files, $info)
}

sub extract {
    my ($self, $filename, $save, $params, $list, $passwords) = @_;

    $list   //= ($self->info($filename))[0];
    $params //= [];
    my @passwords = @{ $passwords // [] };

    push @$params, '-y'  if !grep /^-y/,  @$params;
    push @$params, '-so' if !grep /^-so/, @$params;
    for my $pass_param ( grep /^-p/, @$params ) {
        push @passwords, $pass_param =~ s/^-p//r;
    }
    # always use (at least) empty password. otherwise it hangs when the archive
    # is password protected (waits for user input)
    if (!grep { $_ eq '' } @passwords) {
        push @passwords, '';
    }
    @$params = grep { $_ !~ /^-p/ } @$params;

    while (defined(my $password = shift @passwords)) {
        my ($pid, $out, $err, $stdin) = $self->run_7zip(
            'x', $filename, [ @$params, "-p$password" ]);
        my ($extracted, $corrupted)
            = $self->process_7zip_out( $out, $err, $stdin, $list, $save);
        waitpid( $pid, 0 );
        # return if at least something succeeded or if we tried all passwords
        if (@$extracted || !@passwords) {
            return ($extracted, $corrupted);
        }
    }
}

sub process_7zip_out {
    my ($self, $out, $err, $stdin, $list, $save_fn) = @_;

    my $reader = IO::Select->new($err, $out);

    my @list = @$list;
    #print Dumper \@list;
    my $file = shift @list;
    my $contents;
    my $error_content;
    my @extracted_files;
    while ( my @ready = $reader->can_read(1000) ) {
        foreach my $fh (@ready) {
            if (defined fileno($out) && defined fileno($fh) && fileno($fh) == fileno($out)) {
                use bytes;
                my $data;
                #print STDERR "read 7z STDOUT\n";
                my $read_bytes = $fh->sysread($data, 4096);
                $contents .= $data;
                #print STDERR Dumper $file;
                if ($file && length($contents) >= $file->{size}) {
                    push @extracted_files, $save_fn->(
                        substr($contents, 0, $file->{size}),
                        $file,
                    );
                    #print STDERR "contents length: ".length($contents)."\n";
                    $contents = substr($contents, $file->{size});
                    $file = shift @list;
                }
                #print STDERR "done reading STDOUT\n";
                if ($read_bytes == 0) {
                    $reader->remove($fh);
                    $fh->close();
                }
            }
            if (defined fileno($err) && defined fileno($fh) && fileno($fh) == fileno($err)) {
                my $data;
                my $read_bytes = $fh->sysread($data, 4096);
                $error_content .= $data;
                if ($read_bytes == 0) {
                    $reader->remove($fh);
                    $fh->close();
                }
            }
        }
    }
    $stdin->close();
    if ($contents) {
        print Dumper $file;
        push @extracted_files, $save_fn->($contents, $file);
    }

    my @corrupted_paths;
    for my $line (split(/\n/, $error_content), "\n") {
        if (my ($path) = $line =~ /Extracting *(.*?) *CRC Failed$/) {
            push @corrupted_paths, $path;
        }
        if (my ($path) = $line =~ /Extracting *(.*?) *Data Error/) {
            push @corrupted_paths, $path;
        }
    }


    return \@extracted_files, \@corrupted_paths
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
a function for saving extracted files. The archive gets extracted and the user-defined
function (which gets the file data blob and the filename) is called for each
file extracted from the archive.

=head1 LICENSE

Copyright (C) Týnovský Miroslav.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 AUTHOR

Týnovský Miroslav E<lt>tynovsky@avast.comE<gt>

=cut

