use strict;
use Test::More tests => 1;
use Test::Exception;
use Unpack::SevenZip;
use Data::Dumper;


throws_ok {
    my $unpacker = Unpack::SevenZip->new({ sevenzip => 'ls' });
} qr/doesn't seem to be 7zip/, 'throw exception on wrong 7zip binary';
