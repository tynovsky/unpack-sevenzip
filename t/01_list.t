use strict;
use Test::More tests => 3 + 5;
use Unpack::SevenZip;
use Data::Dumper;

my $unpacker = Unpack::SevenZip->new();

my ($files, $info) =  $unpacker->info('t/archive.7z');

is(@$files, 24, 'there are 24 files in the archive');
is($files->[20]->{size}, 140288, '19th filesize is correct');
is($files->[20]->{path}, '7zS.sfx', '19th filepath is correct');

ok(defined $info->{$_}, "info contains key $_")
    for qw(solid blocks method type path);


