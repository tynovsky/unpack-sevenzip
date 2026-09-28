use strict;
use warnings;
use Test::More;
use lib 't/lib';
use SevenZipTest;
use Unpack::SevenZip;

my $unpacker = Unpack::SevenZip->new({ sevenzip => SevenZipTest::sevenzip() });

my $params = ['-pX'];
my ($files, $info) = $unpacker->info('t/archive.7z', $params);

is(@$files, 24, 'there are 24 files in the archive');
is($files->[20]->{size}, 140288, '19th filesize is correct');
is($files->[20]->{path}, '7zS.sfx', '19th filepath is correct');
is_deeply($params, ['-pX'], 'params not modified');

ok(defined $info->{$_}, "info contains key $_")
    for qw(solid blocks method type path);

done_testing;
