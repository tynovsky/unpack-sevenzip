[![Actions Status](https://github.com/tynovsky/unpack-sevenzip/actions/workflows/test.yml/badge.svg?branch=master)](https://github.com/tynovsky/unpack-sevenzip/actions?workflow=test)
# NAME

Unpack::SevenZip - list and extract archives with 7-Zip, into memory

# SYNOPSIS

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

# DESCRIPTION

Unpack::SevenZip runs the 7-Zip command line program and extracts archives
of any format it can read (zip, 7z, rar, tar, gzip, bzip2, xz, iso, cab,
...) into memory: for each file in the archive a callback gets the content
of the file. Nothing is written to the disk.

It works by running `7z x -so`, which writes the contents of all the files
to its standard output, one after another, and splitting the output into
files by their sizes from the list of files in the archive (`7z l`).

7-Zip is executed directly (without a shell), so archive names and
switches may contain any characters. ARRAY references passed to the
methods are never modified. Nothing is printed to STDOUT.

[Unpack::Custom](https://metacpan.org/pod/Unpack%3A%3ACustom) builds on this module and lets you define what happens
before, during and after extracting, including recursive extraction.

# METHODS

## new(\\%args)

Arguments (all optional):

- sevenzip

    Path to the 7-Zip binary (default `7z`).

- verbose

    Warn about files which were listed but not extracted.

Dies if `sevenzip` can't be run or is not 7-Zip.

## info($archive, \\@switches)

Lists the archive. Returns

- an ARRAY reference of the files in the archive, in the order they are
stored: HASH references with the keys `path`, `size` (missing when 7-Zip
does not know it, e.g. for `bzip2`) and `folder` (`+` for directories, if
the format has it). A file without a name (e.g. in `bzip2`) gets the name of
the archive without its extension, as with `7z x`.
- a HASH reference with information about the archive (`type`, `method`,
`solid`, `physical size`, ...; the lowercased keys printed by
`7z l -slt`), undefined when the file is not an archive.

The list is empty when the file is not an archive 7-Zip can open (or it
has encrypted headers and no or a wrong password was given). Pass a
password switch, e.g. `['-pPASSWORD']`, to list archives with encrypted
headers.

## extract($archive, $save, \\@switches, $list, \\@passwords)

Extracts the archive and calls `$save->($contents, $file)` for each
file in it (directories are skipped). `$contents` is the whole content of
the file as a byte string, `$file` is an item of `$list`.

- \\@switches

    Additional 7-Zip switches, e.g. `['-x!*.log']`. `-p` switches are used
    as passwords.

- $list

    The files 7-Zip extracts, as returned by `info` (the default, so the
    archive is listed first). It must contain exactly the files 7-Zip
    extracts, in the same order, otherwise the output is split incorrectly:
    when you exclude files by switches, remove them from the list too.

- \\@passwords

    Passwords to try. The passwords from the `-p` switches and the empty
    password are tried too, in this order, until something is extracted.

Returns three ARRAY references:

- the values returned by `$save`,
- the paths of the files 7-Zip reported as corrupted (CRC error, data error,
wrong password, ...) or whose content was cut off; their (possibly damaged)
content may have been passed to `$save`,
- the items of `$list` which were not extracted.

The exit code of 7-Zip is stored in `$unpacker->{last_exit_code}`
(also by `info`).

## run\_7zip($command, $archive, \\@switches, \\@files)

Starts 7-Zip with the given command (e.g. `l`, `x`) and returns its pid
and its stdout, stderr and stdin handles; used by `info` and `extract`.
Read both output handles and call `waitpid` on the pid.

# REQUIREMENTS

The 7-Zip command line program `7z`, e.g. the `7zip` package (or the
older `p7zip-full`) on Debian and Ubuntu; RAR archives need the `7zip-rar`
package there. Both 7-Zip 15 and newer and the older p7zip are supported.

# LIMITATIONS

Each extracted file is kept in memory until it is passed to `$save`, so
the largest file in an archive has to fit into memory.

# SEE ALSO

[Unpack::Custom](https://metacpan.org/pod/Unpack%3A%3ACustom)

# LICENSE

Copyright (C) Týnovský Miroslav.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

# AUTHOR

Týnovský Miroslav <tynovsky@seznam.cz>
