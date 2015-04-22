[![Build Status](https://travis-ci.org/tynovsky/unpack-sevenzip.svg?branch=master)](https://travis-ci.org/tynovsky/unpack-sevenzip)
# NAME

Unpack::SevenZip - p7zip wrapper

# SYNOPSIS

    use Unpack::SevenZip;

# DESCRIPTION

Unpack::SevenZip is a wrapper over p7zip tool. It allows you to define
a function for saving extracted files. The archive gets extracted and the user-defined
function (which gets the file data blob and the filename) is called for each
file extracted from the archive.

# LICENSE

Copyright (C) Týnovský Miroslav.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

# AUTHOR

Týnovský Miroslav <tynovsky@avast.com>
