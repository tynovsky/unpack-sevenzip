use strict;
use Test::More 0.98;
use Unpack::SevenZip;
use IO::Select;

my $unpacker = Unpack::SevenZip->new();

my ($h, $out, $err) = $unpacker->run_7zip('x', 't/archive.7z', ['-so'] );
print Dumper $h;
ok($h, 'Got the process handle');

my $everything_ok = 0;

1 while ( $h->pump );
$^O ne 'MSWin32'
    && like($$err, qr/Everything is Ok/, '7zip says: "Everything is Ok"');


done_testing;
