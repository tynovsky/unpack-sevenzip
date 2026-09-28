[![Actions Status](https://github.com/tynovsky/unpack-sevenzip/actions/workflows/test.yml/badge.svg)](https://github.com/tynovsky/unpack-sevenzip/actions)
# NAME

Unpack::SevenZip - p7zip wrapper

# SYNOPSIS

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

# DESCRIPTION

Unpack::SevenZip is a wrapper over p7zip tool. It allows you to define
a function for saving extracted files. The archive gets extracted and the user-defined
function (which gets the file data blob and the filename) is called for each
file extracted from the archive.

7z is executed directly (without a shell), so archive names and switches
may contain any characters. Array references passed to the methods are
never modified.

# METHODS

## new(\\%args)

Dies if `sevenzip` (default `7z`) is not a 7-Zip binary. Set `verbose`
to get warnings about files which were listed but not extracted.

## info($archive, \\@switches)

Returns an ARRAY reference of the files in the archive (hashes with keys
`path`, `size` and `folder`; `size` is missing when it is unknown) and
a HASH reference with information about the archive.

## extract($archive, $save, \\@switches, $list, \\@passwords)

Calls `$save->($contents, $file)` for each extracted file, where
`$file` is an item of `$list` (by default the result of `info`). All
passwords (from `\@passwords` and `-p` switches, and the empty password)
are tried until something is extracted. Returns ARRAY references of the
values returned by `$save`, of the paths of corrupted files and of the
files from `$list` which were not extracted. The exit code of 7z is
stored in `$unpacker->{last_exit_code}`.

## run\_7zip($command, $archive, \\@switches, \\@files)

Starts 7z and returns its pid and its stdout, stderr and stdin handles.

# LICENSE

Copyright (C) Týnovský Miroslav.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

# AUTHOR

Týnovský Miroslav <tynovsky@seznam.cz>
