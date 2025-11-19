#!perl -T

use Test::More tests => 12;
use IO::Scalar;

use File::Temp;
use Digest::SHA;

BEGIN {
    use_ok( 'Archive::Tar::Stream' ) || print "Bail out!\n";
}

my %files = (
    a => 511,
    b => 512,
    c => 513,
    d => 0,
    y => 1,
    z => 12,
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

$ts->AddLink("link", "target", mtime => 1317933200);

# 7 headers, plus 6 blocks in total for the 6 files
is($ts->OutPos(), 512 * 13, "Output Size");

my $sha1 = Digest::SHA->new(1);
$tarfile->seek(0, 0);
$sha1->addfile($tarfile);

my $expected = $sha1->hexdigest();

my $tar2 = File::Temp->new();
$tarfile->seek(0, 0);
my $ts2 = Archive::Tar::Stream->new(infh => $tarfile, outfh => $tar2);

$ts2->StreamCopy(sub { return 'KEEP' });

my $sha2 = Digest::SHA->new(1);
$tar2->seek(0, 0);
$sha2->addfile($tar2);

is($sha2->hexdigest(), $expected, "File Number 2");

$tarfile->seek(0, 0);
my $ts3 = Archive::Tar::Stream->new(infh => $tarfile);

$ts3->StreamCopy(sub {
  my ($header, $offset, $fh) = @_;

  if ($header->{typeflag}) {
    is($header->{linkname}, "target");
    is($header->{size}, 0);
  }
  else {
    is($header->{size}, $files{$header->{name}}, "File $header->{name}");
  }

    return 'SKIP';
});

1;
