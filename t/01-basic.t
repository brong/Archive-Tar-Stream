#!perl -T

use Test::More tests => 11;
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

# 5 headers, plus 4 blocks in total for the 4 files
is($ts->OutPos(), 512 * 9, "Output Size");

my $sha1 = Digest::SHA->new(1);
$tarfile->seek(0, 0);
$sha1->addfile($tarfile);

my $expected = '3daf076bd583e7f0071c5a06713ddc3e0b281ff8';

is($sha1->hexdigest(), $expected, "Initial File");

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
