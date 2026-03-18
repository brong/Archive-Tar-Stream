#!perl -T

use strict;
use warnings;
use Test::More;
use File::Temp;
use File::Path qw(mkpath);
use Digest::SHA;

BEGIN {
    use_ok( 'Archive::Tar::Stream' ) || print "Bail out!\n";
}

# Taint-safe PATH
$ENV{PATH} = "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin";
delete @ENV{qw(IFS CDPATH ENV BASH_ENV)};

my $BSDTAR = '/usr/bin/bsdtar';
unless (-x $BSDTAR) {
    plan skip_all => "bsdtar not found at $BSDTAR";
}

my $MTIME = 1700000000;

# ============================================================
# Helper: create a test directory tree
# ============================================================

sub create_test_tree {
  my ($dir) = @_;

  my $longdir = "$dir/" . "a" x 50 . "/" . "b" x 50;
  mkpath($longdir);

  my %files = (
    "$dir/empty"       => "",
    "$dir/onebyte"     => "x",
    "$dir/exactblock"  => "B" x 512,
    "$dir/blockplus1"  => "C" x 513,
    "$dir/blockminus1" => "D" x 511,
    "$longdir/" . "c" x 60 . ".txt" => "long name content here",
  );

  for my $path (sort keys %files) {
    open my $fh, '>', $path or die "Can't write $path: $!";
    print $fh $files{$path};
    close $fh;
  }

  # symlink (short target)
  symlink("onebyte", "$dir/shortlink") or die "symlink: $!";

  # symlink with long target
  my $linktarget = "a" x 50 . "/" . "b" x 50 . "/" . "c" x 60 . ".txt";
  symlink($linktarget, "$dir/longlink") or die "symlink: $!";

  return %files;
}

# ============================================================
# Part 1: read a tar created by bsdtar
# ============================================================

subtest "read bsdtar-created archive" => sub {
  my $srcdir = File::Temp->newdir();
  my %files = create_test_tree("$srcdir");

  # Create tar with bsdtar
  my $tarfile = File::Temp->new(SUFFIX => '.tar');
  my $tarpath = "$tarfile";
  ($tarpath) = $tarpath =~ /^(.+)$/;
  my $srcpath = "$srcdir";
  ($srcpath) = $srcpath =~ /^(.+)$/;

  system($BSDTAR, 'cf', $tarpath, '--format=gnutar', '-C', $srcpath, '.') == 0
    or die "bsdtar create failed: $?";

  # Read with our module
  open my $infh, '<', $tarpath or die "Can't open $tarpath: $!";
  my $ts = Archive::Tar::Stream->new(infh => $infh);

  my %seen;
  while (my $header = $ts->ReadHeader()) {
    my $name = $header->{name};
    # bsdtar may include trailing / for dirs, normalise
    $seen{$name} = $header;

    if ($header->{typeflag} eq '0' || $header->{typeflag} eq '') {
      # regular file: read content and verify size
      if ($header->{size} > 0) {
        my $nblocks = int(($header->{size} + 511) / 512);
        my $data = $ts->ReadBlocks($nblocks);
        $data = substr($data, 0, $header->{size});

        for my $path (keys %files) {
          (my $relpath = $path) =~ s{^\Q$srcdir\E/}{./};
          if ($relpath eq $name) {
            is(length($data), length($files{$path}),
              "size matches for $name");
            is($data, $files{$path},
              "content matches for $name");
          }
        }
      }
    }
    elsif ($header->{typeflag} eq '5') {
      # directory, ok
    }
    elsif ($header->{typeflag} eq '2') {
      ok(length($header->{linkname}) > 0, "symlink $name has target");
    }
    else {
      $ts->DumpBytes($header->{size}) if $header->{size};
    }
  }
  close $infh;

  my $longrel = "./" . "a" x 50 . "/" . "b" x 50 . "/" . "c" x 60 . ".txt";
  ok(exists $seen{$longrel}, "found long-named file in bsdtar archive");

  ok(exists $seen{"./shortlink"}, "found short symlink");
  ok(exists $seen{"./longlink"}, "found long symlink");

  if ($seen{"./longlink"}) {
    my $expected_target = "a" x 50 . "/" . "b" x 50 . "/" . "c" x 60 . ".txt";
    is($seen{"./longlink"}{linkname}, $expected_target,
      "long symlink target read correctly from bsdtar archive");
  }
};

# ============================================================
# Part 2: read a bsdtar pax-format archive
# ============================================================

subtest "read bsdtar pax-format archive" => sub {
  my $srcdir = File::Temp->newdir();
  my %files = create_test_tree("$srcdir");

  # Create tar with bsdtar in default pax format
  my $tarfile = File::Temp->new(SUFFIX => '.tar');
  my $tarpath = "$tarfile";
  ($tarpath) = $tarpath =~ /^(.+)$/;
  my $srcpath = "$srcdir";
  ($srcpath) = $srcpath =~ /^(.+)$/;

  system($BSDTAR, 'cf', $tarpath, '--format=pax', '-C', $srcpath, '.') == 0
    or die "bsdtar create (pax) failed: $?";

  # Read with our module - pax extended headers (typeflag 'x') will appear
  # as entries we don't specially handle yet, but we should at least not
  # crash, and short-named files should still be readable.
  open my $infh, '<', $tarpath or die "Can't open $tarpath: $!";
  my $ts = Archive::Tar::Stream->new(infh => $infh);

  my %seen;
  my $errors = 0;
  eval {
    while (my $header = $ts->ReadHeader()) {
      $seen{$header->{name}} = $header;
      $ts->DumpBytes($header->{size}) if $header->{size};
    }
  };
  $errors++ if $@;

  is($errors, 0, "no errors reading pax-format archive");
  # pax archives should still have the basic ustar header names
  # (the pax extended header overrides them, but we don't parse that yet)
  ok(scalar keys %seen > 0, "parsed at least some entries from pax archive");
};

# ============================================================
# Part 3: write a tar that bsdtar can extract without warnings
# ============================================================

subtest "bsdtar reads our archive" => sub {
  my $longname = "a" x 50 . "/" . "b" x 50 . "/" . "c" x 60 . ".txt";
  my $longlink_target = "d" x 50 . "/" . "e" x 60 . ".dat";

  my %testfiles = (
    "empty"       => "",
    "onebyte"     => "x",
    "exactblock"  => "B" x 512,
    "blockplus1"  => "C" x 513,
    "blockminus1" => "D" x 511,
    $longname     => "long name content here",
  );

  # Create tar with our module
  my $tarfile = File::Temp->new(SUFFIX => '.tar');
  my $ts = Archive::Tar::Stream->new(outfh => $tarfile);

  for my $name (sort keys %testfiles) {
    my $content = $testfiles{$name};
    my $fh = File::Temp->new();
    $fh->print($content);
    $fh->seek(0, 0);
    $ts->AddFile($name, length($content), $fh, mtime => $MTIME);
  }

  $ts->AddLink("shortlink", "onebyte", mtime => $MTIME);
  $ts->AddLink("longlink", $longlink_target, mtime => $MTIME);

  $ts->FinishTar();

  # Extract with bsdtar and capture stderr
  my $extractdir = File::Temp->newdir();
  my $tarpath = "$tarfile";
  ($tarpath) = $tarpath =~ /^(.+)$/;
  my $extractpath = "$extractdir";
  ($extractpath) = $extractpath =~ /^(.+)$/;

  my $stderr_file = File::Temp->new();
  my $stderr_path = "$stderr_file";
  ($stderr_path) = $stderr_path =~ /^(.+)$/;

  system("$BSDTAR xf \Q$tarpath\E -C \Q$extractpath\E 2>\Q$stderr_path\E");
  my $exit = $? >> 8;

  open my $efh, '<', $stderr_path or die "Can't read stderr: $!";
  my $stderr = do { local $/; <$efh> };
  close $efh;

  is($exit, 0, "bsdtar extract exits cleanly");
  is($stderr, "", "bsdtar extract produces no warnings");

  # Verify extracted files
  for my $name (sort keys %testfiles) {
    my $path = "$extractpath/$name";
    ($path) = $path =~ /^(.+)$/;
    ok(-f $path, "extracted file exists: $name");
    if (-f $path) {
      open my $fh, '<', $path or die "Can't read $path: $!";
      my $got = do { local $/; <$fh> };
      close $fh;
      is($got, $testfiles{$name}, "content matches: $name");
    }
  }

  # Verify symlinks
  my $sl_short = "$extractpath/shortlink";
  ($sl_short) = $sl_short =~ /^(.+)$/;
  ok(-l $sl_short, "shortlink is a symlink");
  is(readlink($sl_short), "onebyte", "shortlink target correct");

  my $sl_long = "$extractpath/longlink";
  ($sl_long) = $sl_long =~ /^(.+)$/;
  ok(-l $sl_long, "longlink is a symlink");
  is(readlink($sl_long), $longlink_target, "longlink target correct");
};

done_testing();
