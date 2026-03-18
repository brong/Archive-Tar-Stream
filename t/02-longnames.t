#!perl -T

use strict;
use warnings;
use Test::More;
use File::Temp;
use Digest::SHA;

BEGIN {
    use_ok( 'Archive::Tar::Stream' ) || print "Bail out!\n";
}

# Helper: read a tar file block-by-block and return a list of
# human-readable block descriptions.  Uses ParseHeader directly
# (which does NOT consume L/K entries) so we see the raw structure.
#
# Output tokens:
#   L(name,SIZE)       - GNU long name header, SIZE bytes of name data follow
#   K(name,SIZE)       - GNU long link header, SIZE bytes of link data follow
#   H(name,SIZE)       - regular file header
#   S(name,link)       - symlink header
#   D(N)               - N data blocks
#   Z                  - zero block (end-of-archive marker)
#   ?                  - unknown/corrupt block

sub describe_tar {
  my ($fh) = @_;
  seek($fh, 0, 0);
  my $ts = Archive::Tar::Stream->new();  # no infh/outfh, just for ParseHeader
  my @desc;

  while (1) {
    my $block;
    my $n = read($fh, $block, 512);
    last unless $n && $n == 512;

    # all-zero block
    if ($block eq "\0" x 512) {
      push @desc, "Z";
      next;
    }

    my $header = $ts->ParseHeader($block);
    unless ($header) {
      push @desc, "?";
      next;
    }

    my $name = $header->{name};
    my $type = $header->{typeflag};
    my $size = $header->{size};

    if ($type eq 'L') {
      push @desc, "L($name,$size)";
    }
    elsif ($type eq 'K') {
      push @desc, "K($name,$size)";
    }
    elsif ($type eq '2') {
      push @desc, "S($name,$header->{linkname})";
    }
    else {
      push @desc, "H($name,$size)";
    }

    # consume data blocks
    if ($size > 0) {
      my $datablocks = int(($size + 511) / 512);
      my $buf;
      read($fh, $buf, $datablocks * 512);
      push @desc, "D($datablocks)";
    }
  }

  return @desc;
}

# Truncate a string to at most 100 bytes (what pack "a100" does to the name)
sub trunc { substr($_[0], 0, 100) }

# --- test data ---

my $longname = "a" x 50 . "/" . "b" x 50 . "/" . "c" x 50 . ".txt";  # 156 bytes
my $longnamelink = $longname . ".link";  # 161 bytes
my $longlink = "target/" . "d" x 100 . ".txt";  # 111 bytes
my $shortname = "short.txt";
my $shortlink = "tgt";

my $MTIME = 1700000000;

# ============================================================
# Test 1: create a tar with long and short filenames, verify
#          raw block structure
# ============================================================

my $tarfile = File::Temp->new();
my $ts = Archive::Tar::Stream->new(outfh => $tarfile);

# long-named file with 11 bytes of content
my $fh1 = File::Temp->new();
$fh1->print("hello world");
$fh1->seek(0, 0);
$ts->AddFile($longname, 11, $fh1, mtime => $MTIME);

# long-named symlink with long target
$ts->AddLink($longnamelink, $longlink, mtime => $MTIME);

# short-named file
my $fh2 = File::Temp->new();
$fh2->print("short");
$fh2->seek(0, 0);
$ts->AddFile($shortname, 5, $fh2, mtime => $MTIME);

$ts->FinishTar();

# L/K data size = length of name/link + 1 for the NUL terminator
my $longname_datasize = length($longname) + 1;       # 157
my $longnamelink_datasize = length($longnamelink) + 1; # 162
my $longlink_datasize = length($longlink) + 1;        # 112
my $trunc_longlink = trunc($longlink);

my @blocks = describe_tar($tarfile);
is_deeply(\@blocks, [
  "L(././\@LongLink,$longname_datasize)", "D(1)",
  "H(" . trunc($longname) . ",11)", "D(1)",
  "L(././\@LongLink,$longnamelink_datasize)", "D(1)",
  "K(././\@LongLink,$longlink_datasize)", "D(1)",
  "S(" . trunc($longnamelink) . ",$trunc_longlink)",
  "H($shortname,5)", "D(1)",
  "Z", "Z",
], "Raw block structure of long-name tar");

# ============================================================
# Test 2: read back and verify ReadHeader returns correct names
# ============================================================

$tarfile->seek(0, 0);
my $ts2 = Archive::Tar::Stream->new(infh => $tarfile);

my $h1 = $ts2->ReadHeader();
is($h1->{name}, $longname, "Long filename read back correctly");
is($h1->{size}, 11, "Long filename file size correct");
$ts2->DumpBytes($h1->{size});

my $h2 = $ts2->ReadHeader();
is($h2->{name}, $longnamelink, "Long name for symlink read back");
is($h2->{linkname}, $longlink, "Long linkname read back correctly");
is($h2->{typeflag}, '2', "Link typeflag correct");

my $h3 = $ts2->ReadHeader();
is($h3->{name}, $shortname, "Short filename still works");
is($h3->{size}, 5, "Short filename file size correct");

# ============================================================
# Test 3: round-trip KEEP - SHA1 must match
# ============================================================

my $tar_rt = File::Temp->new();
$tarfile->seek(0, 0);
my $ts3 = Archive::Tar::Stream->new(infh => $tarfile, outfh => $tar_rt);
$ts3->StreamCopy(sub { return 'KEEP' });
$ts3->FinishTar();

my $sha_orig = Digest::SHA->new(1);
$tarfile->seek(0, 0);
$sha_orig->addfile($tarfile);

my $sha_rt = Digest::SHA->new(1);
$tar_rt->seek(0, 0);
$sha_rt->addfile($tar_rt);

is($sha_rt->hexdigest(), $sha_orig->hexdigest(), "Round-trip KEEP SHA1 matches");

# ============================================================
# Test 4: SKIP a long-filename file
# ============================================================

my $tar_skip = File::Temp->new();
$tarfile->seek(0, 0);
my $ts4 = Archive::Tar::Stream->new(infh => $tarfile, outfh => $tar_skip);
$ts4->StreamCopy(sub {
  my ($header) = @_;
  return 'SKIP' if $header->{name} eq $longname;
  return 'KEEP';
});

my @skip_blocks = describe_tar($tar_skip);
is_deeply(\@skip_blocks, [
  "L(././\@LongLink,$longnamelink_datasize)", "D(1)",
  "K(././\@LongLink,$longlink_datasize)", "D(1)",
  "S(" . trunc($longnamelink) . ",$trunc_longlink)",
  "H($shortname,5)", "D(1)",
], "SKIP long-name file removes its L entry and data");

# ============================================================
# Test 5: rename long -> short during StreamCopy
# ============================================================

my $tar_l2s = File::Temp->new();
$tarfile->seek(0, 0);
my $ts5 = Archive::Tar::Stream->new(infh => $tarfile, outfh => $tar_l2s);
$ts5->StreamCopy(sub {
  my ($header) = @_;
  if ($header->{name} eq $longname) {
    $header->{name} = "renamed.txt";
    return ('KEEP', $header);
  }
  return 'KEEP';
});

my @l2s_blocks = describe_tar($tar_l2s);
is_deeply(\@l2s_blocks, [
  "H(renamed.txt,11)", "D(1)",
  "L(././\@LongLink,$longnamelink_datasize)", "D(1)",
  "K(././\@LongLink,$longlink_datasize)", "D(1)",
  "S(" . trunc($longnamelink) . ",$trunc_longlink)",
  "H($shortname,5)", "D(1)",
], "Long->short rename drops L entry");

# verify we can read the renamed file back
$tar_l2s->seek(0, 0);
my $ts5r = Archive::Tar::Stream->new(infh => $tar_l2s);
my $h5 = $ts5r->ReadHeader();
is($h5->{name}, "renamed.txt", "Renamed long->short name reads back");

# ============================================================
# Test 6: rename short -> long during StreamCopy
# ============================================================

my $newlong = "x" x 60 . "/" . "y" x 60 . ".dat";  # 125 bytes
my $newlong_datasize = length($newlong) + 1;

my $tar_s2l = File::Temp->new();
$tarfile->seek(0, 0);
my $ts6 = Archive::Tar::Stream->new(infh => $tarfile, outfh => $tar_s2l);
$ts6->StreamCopy(sub {
  my ($header) = @_;
  if ($header->{name} eq $shortname) {
    $header->{name} = $newlong;
    return ('KEEP', $header);
  }
  return 'KEEP';
});

my @s2l_blocks = describe_tar($tar_s2l);
is_deeply(\@s2l_blocks, [
  "L(././\@LongLink,$longname_datasize)", "D(1)",
  "H(" . trunc($longname) . ",11)", "D(1)",
  "L(././\@LongLink,$longnamelink_datasize)", "D(1)",
  "K(././\@LongLink,$longlink_datasize)", "D(1)",
  "S(" . trunc($longnamelink) . ",$trunc_longlink)",
  "L(././\@LongLink,$newlong_datasize)", "D(1)",
  "H(" . trunc($newlong) . ",5)", "D(1)",
], "Short->long rename adds L entry");

# verify we can read the renamed file back
$tar_s2l->seek(0, 0);
my $ts6r = Archive::Tar::Stream->new(infh => $tar_s2l);
$ts6r->ReadHeader();  # skip first file
$ts6r->DumpBytes(11);
$ts6r->ReadHeader();  # skip symlink
my $h6 = $ts6r->ReadHeader();
is($h6->{name}, $newlong, "Renamed short->long name reads back");

# ============================================================
# Test 7: rename long link target to short, and long name to short
# ============================================================

my $tar_lk2s = File::Temp->new();
$tarfile->seek(0, 0);
my $ts7 = Archive::Tar::Stream->new(infh => $tarfile, outfh => $tar_lk2s);
$ts7->StreamCopy(sub {
  my ($header) = @_;
  if ($header->{linkname} eq $longlink) {
    $header->{name} = "mylink";
    $header->{linkname} = $shortlink;
    return ('KEEP', $header);
  }
  return 'KEEP';
});

my @lk2s_blocks = describe_tar($tar_lk2s);
is_deeply(\@lk2s_blocks, [
  "L(././\@LongLink,$longname_datasize)", "D(1)",
  "H(" . trunc($longname) . ",11)", "D(1)",
  "S(mylink,$shortlink)",
  "H($shortname,5)", "D(1)",
], "Long link->short link drops both L and K entries");

done_testing();
