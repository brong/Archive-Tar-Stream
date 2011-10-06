#!perl -T

use Test::More tests => 8;
use IO::Scalar;

use File::Temp;
use Digest::SHA1;

BEGIN {
    use_ok( 'Archive::Tar::Stream' ) || print "Bail out!\n";
}

my %files = (
    a => 511,
    b => 512,
    c => 513,
);

my $tarfile = File::Temp->new();

my $ts = Archive::Tar::Stream->new(outfh => $tarfile);
ok($ts);

foreach my $name (sort keys %files) {
  my $fh = File::Temp->new();
  $fh->print($name x $files{$name});
  $fh->seek(0, 0);
  # fixed mtime so the sha1 matches
  $ts->AddFile($name, $files{$name}, $fh, mtime => 1317933200);
}

is($ts->OutPos(), 512 * 7, "Output Size");

my $sha1 = Digest::SHA1->new();
$tarfile->seek(0, 0);
$sha1->addfile($tarfile);

is($sha1->hexdigest(), 'fcd8a6e5712f462185911d53af5aad4201e6d345', "Initial File");

my $tar2 = File::Temp->new();
$tarfile->seek(0, 0);
my $ts2 = Archive::Tar::Stream->new(infh => $tarfile, outfh => $tar2);

$ts2->StreamCopy(sub { return 'KEEP' });

my $sha2 = Digest::SHA1->new();
$tar2->seek(0, 0);
$sha2->addfile($tar2);

is($sha2->hexdigest(), 'fcd8a6e5712f462185911d53af5aad4201e6d345', "File Number 2");

$tarfile->seek(0, 0);
my $ts3 = Archive::Tar::Stream->new(infh => $tarfile);

$ts3->StreamCopy(sub {
    my ($header, $offset, $fh) = @_;

    is($header->{size}, $files{$header->{name}}, "File $header->{name}");

    return 'SKIP';
});

1;
