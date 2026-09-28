package SevenZipTest;

use strict;
use warnings;

use Test::More;
use Unpack::SevenZip;

sub sevenzip { $ENV{SEVENZIP} // '7z' }

# skip the whole test file when 7-Zip is not installed
sub import {
    my $ok = eval { Unpack::SevenZip->new({ sevenzip => sevenzip() }); 1 };
    plan skip_all => '7-Zip (7z) not found, set SEVENZIP to its path' if ! $ok;
}

1;
