package Unpack::SevenZip;

use strict;
use warnings;
use Data::Dumper;

#use IPC::Open3;
use IO::Handle;
use IO::Select;
use IPC::Run qw( start pump finish timeout binary );

our $VERSION = "0.01";

sub new {
    my ($class, $args) = @_;
    $args //= { };
    $args->{sevenzip} //= 'C:\\Program Files\\7-Zip\\7z.exe';
    #: '7z';

    my $output_7z = qx($args->{sevenzip});
    die "Program '$args->{sevenzip}' doesn't seem to be 7zip"
        if $output_7z !~ /Igor Pavlov/ || $output_7z !~ /7-Zip/;

    return bless $args, $class;
}

sub run_7zip {
    my ($self, $command, $archive_name, $switches, $files, $stdin) = @_;
    $_ //= [] for $switches, $files;
    $_ //= '' for $command, $archive_name;

    my @cmd = ($command, @$switches, $archive_name, @$files);
    # print STDERR "$cmd\n";

    my ($out, $err);
    my $h = IPC::Run::start (
        [$self->{sevenzip}, @cmd ],
        \$stdin,
        '>', binary, \$out,
        '2>', \$err
    );

    return ($h, \$out, \$err, \$stdin)
}

sub info {
    my ($self, $filename, $params) = @_;

    $params //= [];
    push @$params, '-y';
    push @$params, '-slt';
    push @$params, '-p' if !grep /^-p/, @$params;

    my @cmd = ('l', @$params, $filename);

    my ($stdin, $out, $err);
    my $h = IPC::Run::start (
        [$self->{sevenzip}, @cmd ],
        \$stdin,
        '>', \$out,
        '2>', \$err
    );

    my ($file_list_started, $info_started, @files, $file, $info, $prev_content);
    my $content;

    while ($h->pump) {
        # print STDERR "pump\n";
        if ($out) {
            # print STDERR "out: $$out\n";
            $content .= $out;
            $out = '';
        }
        if ($err) {
            # print STDERR "err: $$err\n";
            $err = '';
        }
    }
    $h->finish;

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
            if (grep $_ eq lc($key), qw(path size folder)) {
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
    $list = [ grep { !exists $_->{folder} || $_->{folder} ne '+' } @$list ];
    $params //= [];
    my @passwords = @{ $passwords // [] };

    push @$params, '-y'  if !grep /^-y/,  @$params;
    push @$params, '-so' if !grep /^-so/, @$params;
    for my $pass_param ( grep /^-p/, @$params ) {
        (my $password = $pass_param) =~ s/^-p//;
        push @passwords, $password;
    }
    # always use (at least) empty password. otherwise it hangs when the archive
    # is password protected (waits for user input)
    if (!grep { $_ eq '' } @passwords) {
        push @passwords, '';
    }
    @$params = grep { $_ !~ /^-p/ } @$params;

    while (defined(my $password = shift @passwords)) {
        my ($h, $out, $err, $stdin) = $self->run_7zip(
            'x', $filename, [ @$params, "-p$password" ]);
        my ($extracted, $corrupted)
            = $self->process_7zip_out($h, $out, $err, $stdin, $list, $save);
        # return if at least something succeeded or if we tried all passwords
        if (@$extracted || !@passwords) {
            return ($extracted, $corrupted);
        }
    }
}

sub process_7zip_out {
    my ($self, $h, $out, $err, $stdin, $list, $save_fn) = @_;

    my @list = @$list;
    my $file = shift @list;
    my $contents;
    my $error_content;
    my @extracted_files;

    while ($h->pump) {
        if ($$out) {
            use bytes;
            $contents .= $$out;
            while ($file && length($contents) >= $file->{size}) {
                push @extracted_files, $save_fn->(
                    substr($contents, 0, $file->{size}, q()),
                    $file,
                );
                $file = shift @list;
            }
            $$out = '';
        }
        if ($$err) {
            $error_content .= $$err;
            $$err = '';
        }
    }
    $h->finish;
    if ($contents) {
        print Dumper $file;
        print "Content size: ", length($contents), "\n";
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

    if (my $error_count = @list) {
        print "ERROR: There are $error_count unsaved files: ", Dumper(\@list);
    }


    return \@extracted_files, \@corrupted_paths
}

1;
__END__

=encoding utf-8

=head1 NAME

Unpack::SevenZip - p7zip wrapper

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

