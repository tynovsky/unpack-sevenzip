use strict;
use warnings;
use Test::More tests => 2;
use Test::Exception;
use Unpack::SevenZip;

throws_ok {
    Unpack::SevenZip->new({ sevenzip => 'ls' });
} qr/doesn't seem to be 7zip/, 'throw exception on wrong 7zip binary';

throws_ok {
    Unpack::SevenZip->new({ sevenzip => '/nonexistent/7z' });
} qr/doesn't seem to be 7zip/, 'throw exception on missing 7zip binary';
