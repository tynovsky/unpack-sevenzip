use strict;
use Test::More 0.98;
use Unpack::SevenZip;
use IO::Select;

my $unpacker = Unpack::SevenZip->new();

my ($pid, $out, $err) = $unpacker->run_7zip('x', 't/archive.7z', ['-so'] );
ok($out, 'Got the output handle');

my $everything_ok = 0;

my $reader = IO::Select->new($err, $out);

while ( my @ready = $reader->can_read() ) {
    foreach my $fh (@ready) {
        if (fileno($fh) == fileno($out)) {
            my $i = 0;
            my $data;
            while ($fh->read(\$data, 4096)) {
                $i++;
                #print STDERR $i, " ";
            }
            if (!$i) {
                # note "close fh";
                $reader->remove($fh);
                $fh->close();
                next
            }
        }
        elsif (fileno($fh) == fileno($err)) {
            my $line = <$fh>;
            if (!defined $line) {
                # note "close fh";
                $reader->remove($fh);
                $fh->close();
                next
            }
            $everything_ok = 1 if $line =~ /^Everything is Ok/;
            # note $line;
        }
    }
}

waitpid(0, $pid);

ok($everything_ok, '7zip says: "Everything is Ok"');


done_testing;
