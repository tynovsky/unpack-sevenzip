use strict;
use warnings;
use Test::More;
use lib 't/lib';
use SevenZipTest;
use Unpack::SevenZip;

my $unpacker = Unpack::SevenZip->new({ sevenzip => SevenZipTest::sevenzip() });

my ($pid, $out, $err, $stdin) = $unpacker->run_7zip('x', 't/archive.7z', ['-so', '-y']);
ok($out, 'Got the output handle');
$stdin->close;

my ($stdout) = Unpack::SevenZip::_read_all($out, $err);
waitpid($pid, 0);

is($? >> 8, 0, '7zip exited successfully');
my ($files) = $unpacker->info('t/archive.7z');
my $size = 0;
$size += $_->{size} for grep { ($_->{folder} // '') ne '+' } @$files;
is(length $stdout, $size, 'all data extracted');

done_testing;
