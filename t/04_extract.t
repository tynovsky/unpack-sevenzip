use strict;
use warnings;
use Test::More;
use lib 't/lib';
use SevenZipTest;
use Unpack::SevenZip;
use File::Temp qw(tempdir);
use File::Copy;
use Cwd qw(getcwd);
use IO::Compress::Bzip2 qw(bzip2 $Bzip2Error);

my $sevenzip = SevenZipTest::sevenzip();
my $unpacker = Unpack::SevenZip->new({ sevenzip => $sevenzip });
my $dir = tempdir(CLEANUP => 1);

sub slurp { open my $fh, '<:raw', $_[0] or die "$_[0]: $!"; local $/; <$fh> }
sub run_7z {
    open my $null, '>', '/dev/null' or die;
    open my $stdout, '>&', \*STDOUT or die;
    open STDOUT, '>&', $null or die;
    my $rc = system $sevenzip, @_;
    open STDOUT, '>&', $stdout or die;
    die "7z @_ failed" if $rc;
}

my $license = slurp('LICENSE');
my $changes = slurp('Changes');
copy('LICENSE', "$dir/LICENSE");
copy('Changes', "$dir/Changes");

# a name which needs quoting in a shell and starts with '-'
my $cwd = getcwd();
chdir $dir or die;
run_7z('a', '-mx0', '--', q{-it's a test.7z}, 'LICENSE', 'Changes');

my %saved;
my $save = sub { my ($contents, $file) = @_; $saved{ $file->{path} } = $contents; $file->{path} };
my $params = ['-pX'];
my ($extracted, $corrupted, $unsaved) = $unpacker->extract(q{-it's a test.7z}, $save, $params);
chdir $cwd or die;

is_deeply([ sort @$extracted ], [qw(Changes LICENSE)], 'files extracted from a strangely named archive');
is($saved{LICENSE}, $license, 'content is correct');
is($saved{Changes}, $changes, 'content is correct');
is_deeply($corrupted, [], 'nothing corrupted');
is_deeply($unsaved, [], 'nothing unsaved');
is_deeply($params, ['-pX'], 'params not modified');

# corrupted archive (stored, so the damage hits the data of LICENSE)
{
    my $archive = "$dir/-it's a test.7z";
    my $data = slurp($archive);
    $data =~ s/Artistic/Artistiq/; # only in LICENSE
    open my $fh, '>:raw', "$dir/corrupted.7z" or die;
    print {$fh} $data;
    close $fh;

    %saved = ();
    my ($extracted, $corrupted) = $unpacker->extract("$dir/corrupted.7z", $save);
    is_deeply($corrupted, ['LICENSE'], 'corrupted file detected');
}

# bzip2: no path and unknown size in the listing
{
    bzip2(\$license => "$dir/license.bz2") or die $Bzip2Error;
    my ($files) = $unpacker->info("$dir/license.bz2");
    is_deeply($files, [ { path => 'license' } ], 'bzip2 listing');

    %saved = ();
    my ($extracted, $corrupted, $unsaved) = $unpacker->extract("$dir/license.bz2", $save);
    is_deeply($extracted, ['license'], 'bzip2 extracted');
    is($saved{license}, $license, 'bzip2 content is correct');
}

# tar without the end-of-archive blocks: 7z prints a warning after the list
{
    system('tar', '-C', $dir, '-cf', "$dir/full.tar", 'LICENSE') == 0 or die 'tar failed';
    my $tar = slurp("$dir/full.tar");
    my $end = 512 + 512 * int((length($license) + 511) / 512);
    open my $fh, '>:raw', "$dir/truncated.tar" or die;
    print {$fh} substr($tar, 0, $end);
    close $fh;

    my ($files) = $unpacker->info("$dir/truncated.tar");
    is(scalar(@$files), 1, 'no empty entries in the listing');
}

# nothing is printed to STDOUT even when the list does not match the output
{
    # keep file descriptor 1 open, 7z's pipes must not get it
    open my $saved_stdout, '>&', \*STDOUT or die;
    open STDOUT, '>', "$dir/stdout" or die;
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    $unpacker->extract("$dir/-it's a test.7z", sub { 1 },
        [], [ { path => 'LICENSE', size => 10 } ]);
    open STDOUT, '>&', $saved_stdout or die;
    is(slurp("$dir/stdout"), '', 'nothing printed to STDOUT');
    ok((grep { /unexpected output/ } @warnings), 'warned about unexpected output');
}

done_testing;
