requires 'perl', '5.010';
requires 'Carp';
requires 'File::Basename';
requires 'IPC::Open3';
requires 'IO::Handle';
requires 'IO::Select';

on 'test' => sub {
    requires 'Test::More', '0.98';
    requires 'Test::Exception';
    requires 'File::Temp';
    requires 'IO::Compress::Bzip2';
};
