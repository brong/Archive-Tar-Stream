package Archive::Tar::Stream;

use strict;
use warnings;

# this is pretty fixed by the format!
use constant BLOCKSIZE => 512;

use constant BLOCKCOUNT => 2048;
use constant BUFSIZE => (512*2048);

# dependencies
use IO::File;
use IO::Handle;
use File::Temp;
use List::Util qw(min);

our $VERBOSE = 0;

=head1 NAME

Archive::Tar::Stream - pure perl IO-friendly tar file management

=head1 VERSION

Version 0.06

=cut

our $VERSION = '0.06';


=head1 SYNOPSIS

Archive::Tar::Stream grew from a requirement to process very large
archives containing email backups, where the IO hit for unpacking
a tar file, repacking parts of it, and then unlinking all the files
was prohibitive.

Archive::Tar::Stream takes two file handles, one purely for reads,
one purely for writes.  It does no seeking, it just unpacks
individual records from the input filehandle, and packs records
to the output filehandle.

This module does not attempt to do any file handle management or
compression for you.  External zcat and gzip are quite fast and
use separate cores.

    use Archive::Tar::Stream;

    # add a file to a new tar
    my $ts = Archive::Tar::Stream->new(outfh => $outfh);
    open my $fh, '<', $path or die;
    $ts->AddFile($name, -s $fh, $fh);

    # remove large non-jpeg files from a tar.gz
    my $infh = IO::File->new("zcat $infile |") || die "oops";
    my $outfh = IO::File->new("| gzip > $outfile") || die "double oops";
    my $ts = Archive::Tar::Stream->new(infh => $infh, outfh => $outfh);
    $ts->StreamCopy(sub {
        my ($header, $outpos, $fh) = @_;

        # we want all small files
        return 'KEEP' if $header->{size} < 64 * 1024;
        # and any other jpegs
        return 'KEEP' if $header->{name} =~ m/\.jpg$/i;

        # need to see the content to decide
        return 'EDIT' unless $fh;

        return 'KEEP' if mimetype_of_filehandle($fh) eq 'image/jpeg';

        # ok, we don't want other big files
        return 'SKIP';
    });


=head1 SUBROUTINES/METHODS

=head2 new

    my $ts = Archive::Tar::Stream->new(%args);

Args:
   infh      - filehandle to read from
   outfh     - filehandle to write to
   inpos     - initial offset in infh
   outpos    - initial offset in outfh
   safe_copy - boolean (default: 1)
   verbose   - boolean (default: 0)

Offsets are for informational purposes only, but can be
useful if you are tracking offsets of items within your
tar files separately.  All read and write functions
update these offsets.  If you don't provide offsets, they
will default to zero.

B<safe_copy> is enabled by default.  When set, every file
being copied from the input stream is first written to a
temporary file before being appended to the output.  This
protects the output tar from corruption if the input is
truncated mid-file: without safe_copy, a truncated input
could leave a partial record in the output (a header
promising N bytes followed by fewer bytes of data), which
is a corrupt tar file.  With safe_copy, the module will
die before writing anything to the output, leaving it
valid up to the last complete record.

The cost is significant: every file's data is written to
disk twice (once to the temp file, once to output).  For
large archives this doubles the IO.  If your input is
reliable (e.g. a local file, not a pipe), or if you don't
need the output to be valid on partial failure, disable it
with C<< safe_copy => 0 >>.

B<verbose> enables diagnostic output to STDOUT showing
KEEP/SKIP/DISCARD decisions during StreamCopy.  The
package global C<$Archive::Tar::Stream::VERBOSE> is also
supported for backward compatibility.

=cut

sub new {
  my $class = shift;
  my %args = @_;
  my $Self = bless {
    # defaults
    safe_copy => 1,
    verbose => 0,
    inpos => 0,
    outpos => 0,
    %args
  }, ref($class) || $class;
  return $Self;
}

=head2 SafeCopy

   $ts->SafeCopy(0);

Toggle the "safe_copy" field mentioned above.

=cut

sub SafeCopy {
  my $Self = shift;
  if (@_) {
    $Self->{safe_copy} = shift;
  }
  return $Self->{safe_copy};
}

=head2 InPos

=head2 OutPos

Read only accessors for the internal position trackers for
the two tar streams.

=cut

sub InPos {
  my $Self = shift;
  return $Self->{inpos};
}

sub OutPos {
  my $Self = shift;
  return $Self->{outpos};
}

=head2 AddFile

Adds a file to the output filehandle, adding sensible
defaults for all the extra header fields.

Requires: outfh

   my $header = $ts->AddFile($name, $size, $fh, %extra);

See TARHEADER for documentation of the header fields.

You must provide 'size' due to the non-seeking nature of
this library, but "-s $fh" is usually fine.

Returns the complete header that was written.

=cut

sub AddFile {
  my $Self = shift;
  my $name = shift;
  my $size = shift;
  my $fh = shift;

  my $header = $Self->BlankHeader(@_, name => $name, size => $size);

  return $size ? $Self->WriteFromFh($fh, $header) : $Self->WriteHeader($header);
}

=head2 AddLink

   my $header = $ts->AddLink($name, $linkname, %extra);

Adds a symlink to the output filehandle.

See TARHEADER for documentation of the header fields.

Returns the complete header that was written.

=cut

sub AddLink {
  my $Self = shift;
  my $name = shift;
  my $linkname = shift;

  my $header = $Self->BlankHeader(typeflag => '2', @_, name => $name, linkname => $linkname);

  return $Self->WriteHeader($header);
}

=head2 StreamCopy

Streams all records from the input filehandle and provides
an easy way to write them to the output filehandle.

Requires: infh
Optional: outfh - required if you return 'KEEP'

    $ts->StreamCopy(sub {
        my ($header, $outpos, $fh) = @_;
        # ...
        return 'KEEP';
    });

GNU long filename and long linkname extensions (typeflag
C<L> and C<K>) are handled transparently: the callback
receives a single header with the full name already
applied.  On the write side, C<L>/C<K> entries are emitted
automatically when needed.  You can freely rename files
to longer or shorter names in the callback and the right
thing happens.

The chooser function can either return a single 'action' or
a tuple of action and a new header.

The action can be:

   KEEP - copy this file as is (possibly changed header) to output tar
   EDIT - re-call $Chooser with filehandle
   SKIP - skip over the file and call $Chooser on the next one
   EXIT - skip and also stop further processing

B<EDIT mode:>

The file will be copied to a temporary file and the
filehandle passed to $Chooser on a second call.  Your
callback can truncate, rewrite, or inspect the contents.
If you change the file, update C<< $header->{size} >> and
return it as C<$newheader>.

You don't have to change the file of course; EDIT is also
useful just to inspect file contents before deciding to
KEEP or SKIP.

A standard usage pattern looks like this:

  $ts->StreamCopy(sub {
    my ($header, $outpos, $fh) = @_;

    # simple checks on the header alone
    return 'KEEP' if do_want($header);
    return 'SKIP' if dont_want($header);

    # need to see the contents to decide
    return 'EDIT' unless $fh;

    # $fh is now a seekable filehandle with the contents
    return 'KEEP' if looks_good($fh);
    return 'SKIP';
  });

=cut

sub StreamCopy {
  my $Self = shift;
  my $Chooser = shift;

  while (my $header = $Self->ReadHeader()) {
    my $pos = $header->{_pos};
    if ($Chooser) {
      my ($rc, $newheader) = $Chooser->($header, $Self->{outpos}, undef);

      my $TempFile;
      my $Edited;

      # positive code means read the file
      if ($rc eq 'EDIT') {
        $Edited = 1;
        $TempFile = $Self->CopyToTempFile($header->{size});
        # call chooser again with the contents
        ($rc, $newheader) = $Chooser->($newheader || $header, $Self->{outpos}, $TempFile);
        seek($TempFile, 0, 0);
      }

      # short circuit exit code
      return if $rc eq 'EXIT';

      # NOTE: even the size could have been changed if it's an edit!
      $header = $newheader if $newheader;

      if ($rc eq 'KEEP') {
        print "KEEP $header->{name} $pos/$Self->{outpos}\n" if ($Self->{verbose} || $VERBOSE);
        if ($TempFile) {
          $Self->WriteFromFh($TempFile, $header);
        }
        # guarantee safety by getting everything into a temporary file first
        elsif ($Self->{safe_copy} and $header->{size}) {
          $TempFile = $Self->CopyToTempFile($header->{size});
          $Self->WriteFromFh($TempFile, $header);
        }
        else {
          $Self->WriteCopy($header);
        }
      }

      # anything else means discard it
      elsif ($rc eq 'SKIP') {
        if ($TempFile) {
          print "LATE REJECT $header->{name} $pos/$Self->{outpos}\n" if ($Self->{verbose} || $VERBOSE);
          # $TempFile already contains the bytes
        }
        else {
          print "DISCARD $header->{name} $pos/$Self->{outpos}\n" if ($Self->{verbose} || $VERBOSE);
          $Self->DumpBytes($header->{size});
        }
      }

      else {
        die "Bogus response $rc from callback\n";
      }
    }
    else {
      print "PASSTHROUGH $header->{name} $Self->{outpos}\n" if ($Self->{verbose} || $VERBOSE);
      if ($Self->{safe_copy} and $header->{size}) {
        my $TempFile = $Self->CopyToTempFile($header->{size});
        $Self->WriteFromFh($TempFile, $header);
      }
      else {
        $Self->WriteCopy($header);
      }
    }
  }
}

=head2 ReadBlocks

Requires: infh

   my $raw = $ts->ReadBlocks($nblocks);

Reads 'n' blocks of 512 bytes from the input filehandle
and returns them as single scalar.

Returns undef at EOF on the input filehandle.  Any further
calls after undef is returned will die.  This is to avoid
naive programmers creating infinite loops.

nblocks is optional, and defaults to 1.

=cut

sub ReadBlocks {
  my $Self = shift;
  my $nblocks = shift || 1;
  unless ($Self->{infh}) {
    die "Attempt to read without input filehandle\n";
  }
  my $bytes = BLOCKSIZE * $nblocks;
  my $buf = '';
  my $pos = 0;
  while ($pos < $bytes) {
    my $chunk = min($bytes - $pos, BUFSIZE);
    my $n = sysread($Self->{infh}, $buf, $chunk, $pos);
    unless ($n) {
      delete $Self->{infh};
      return unless $pos; # nothing at EOF is fine
      die "Failed to read full block at $Self->{inpos}\n";
    }
    $pos += $n;
    $Self->{inpos} += $n;
  }
  return $buf;
}

=head2 WriteBlocks

Requires: outfh

   my $pos = $ts->WriteBlocks($buffer, $nblocks);

Write blocks to the output filehandle.  If the buffer is too
short, it will be padded with zero bytes.  If it's too long,
it will be truncated.

nblocks is optional, and defaults to 1.

Returns the position of the header in the output stream.

=cut

sub WriteBlocks {
  my $Self = shift;
  my $buf = shift;
  my $nblocks = shift || 1;

  my $bytes = BLOCKSIZE * $nblocks;

  unless ($Self->{outfh}) {
    die "Attempt to write without output filehandle\n";
  }
  my $pos = $Self->{outpos};

  # make sure we've got $nblocks times BLOCKSIZE bytes to write
  if (length($buf) < $bytes) {
    $buf .= "\0" x ($bytes - length($buf));
  }

  my $bufpos = 0;
  while ($bufpos < $bytes) {
    my $n = syswrite($Self->{outfh}, $buf, $bytes - $bufpos, $bufpos);
    unless ($n) {
      delete $Self->{outfh};
      die "Failed to write full block at $Self->{outpos}\n";
    }
    $bufpos += $n;
    $Self->{outpos} += $n;
  }

  return $pos;
}

=head2 ReadHeader

Requires: infh

   my $header = $ts->ReadHeader(%Opts);

Read a single record header from the input filehandle and
return it as a TARHEADER format hashref.  Returns undef
at the end of the archive.

GNU long filename (typeflag C<L>) and long linkname
(typeflag C<K>) extensions are consumed transparently:
the returned header will have the full name/linkname
already applied, and C<_pos> will point to the start of
the first extension header.

If the option C<< SkipInvalid => 1 >> is passed, blocks
that fail the checksum test will be silently skipped
rather than treated as end-of-archive.

=cut

sub ReadHeader {
  my $Self = shift;
  my %Opts = @_;

  my ($pos, $header, $skipped) = (0, undef, 0);
  my ($longname, $longlink);

  my $initialpos = $Self->{inpos};
  while (not $header) {
    $pos = $Self->{inpos} unless defined $longname or defined $longlink;
    my $block = $Self->ReadBlocks();
    last unless $block;
    my $parsed = $Self->ParseHeader($block);
    unless ($parsed) {
      last unless $Opts{SkipInvalid};
      $skipped++;
      next;
    }

    # Handle GNU long name extension (typeflag 'L')
    if ($parsed->{typeflag} eq 'L') {
      $longname = $Self->_ReadLongName($parsed->{size});
      next;
    }

    # Handle GNU long link extension (typeflag 'K')
    if ($parsed->{typeflag} eq 'K') {
      $longlink = $Self->_ReadLongName($parsed->{size});
      next;
    }

    $header = $parsed;
  }

  return unless $header;

  if ($skipped) {
    warn "Skipped $skipped blocks - invalid headers at $initialpos\n";
  }

  # Apply long names from GNU extensions
  if (defined $longname) {
    $header->{name} = $longname;
  }
  if (defined $longlink) {
    $header->{linkname} = $longlink;
  }

  $header->{_pos} = $pos;
  $Self->{last_header} = $header;

  return $header;
}

# Read the data blocks following a GNU 'L' or 'K' header and return
# the long name as a string (without trailing NUL).
sub _ReadLongName {
  my $Self = shift;
  my $size = shift;

  my $nblocks = 1 + int(($size - 1) / BLOCKSIZE);
  my $data = $Self->ReadBlocks($nblocks);
  die "Failed to read long name data at $Self->{inpos}\n" unless defined $data;
  $data = substr($data, 0, $size);
  $data =~ s/\0+$//;
  return $data;
}

# Write a GNU 'L' or 'K' long name entry (header + data blocks).
sub _WriteLongEntry {
  my ($Self, $typeflag, $value) = @_;

  my $data = $value . "\0";
  my $header = $Self->BlankHeader(
    name => '././@LongLink',
    typeflag => $typeflag,
    size => length($data),
  );
  my $block = $Self->CreateHeader($header);
  $Self->WriteBlocks($block);
  my $nblocks = 1 + int((length($data) - 1) / BLOCKSIZE);
  $Self->WriteBlocks($data, $nblocks);
}

# Emit GNU 'L'/'K' entries if name or linkname exceed 100 bytes.
sub _WriteLongEntries {
  my ($Self, $header) = @_;

  if (length($header->{name}) > 100) {
    $Self->_WriteLongEntry('L', $header->{name});
  }
  if (length($header->{linkname}) > 100) {
    $Self->_WriteLongEntry('K', $header->{linkname});
  }
}

=head2 WriteHeader

Requires: outfh

   my $newheader = $ts->WriteHeader($header);

Write a header to the output filehandle.  If the name or
linkname exceeds 100 bytes, GNU long name/link extension
entries are emitted automatically before the header.

Returns a copy of the header with _pos set to the position
of the main header in the output file.

=cut

sub WriteHeader {
  my $Self = shift;
  my $header = shift;

  $Self->_WriteLongEntries($header);
  my $block = $Self->CreateHeader($header);
  my $pos = $Self->WriteBlocks($block);
  return( {%$header, _pos => $pos} );
}

=head2 ParseHeader

   my $header = $ts->ParseHeader($block);

Parse a single block of raw bytes into a TARHEADER
format header.  $block must be exactly 512 bytes.

Returns undef if the block fails the checksum test.

=cut

sub ParseHeader {
  my $Self = shift;
  my $block = shift;

  # enforce length
  return unless(512 == length($block));

  # skip empty blocks
  return if substr($block, 0, 1) eq "\0";

  # unpack exactly 15 items from the block
  my @items = unpack("a100a8a8a8a12a12a8a1a100a8a32a32a8a8a155", $block);
  return unless (15 == @items);

  for (@items) {
    s/\0.*//; # strip from first null
  }

  my $chksum = oct($items[6]);
  # do checksum
  substr($block, 148, 8) = "        ";
  unless (unpack("%32C*", $block) == $chksum) {
    return;
  }

  my %header = (
    name => $items[0],
    mode => oct($items[1]),
    uid => oct($items[2]),
    gid => oct($items[3]),
    size => oct($items[4]),
    mtime => oct($items[5]),
    # checksum
    typeflag => $items[7],
    linkname => $items[8],
    # magic
    uname => $items[10],
    gname => $items[11],
    devmajor => oct($items[12]),
    devminor => oct($items[13]),
    prefix => $items[14],
  );

  return \%header;
}

=head2 BlankHeader

  my $header = $ts->BlankHeader(%extra);

Create a header with sensible defaults.  That means
time() for mtime, 0777 for mode, etc.

It then applies any 'extra' fields from %extra to
generate a final header.  Also validates the keys
in %extra to make sure they're all known keys.

=cut

sub BlankHeader {
  my $Self = shift;
  my %hash = (
    name => '',
    mode => 0777,
    uid => 0,
    gid => 0,
    size => 0,
    mtime => time(),
    typeflag => '0', # this is actually the STANDARD plain file format, phooey.  Not 'f' like Tar writes
    linkname => '',
    uname => '',
    gname => '',
    devmajor => 0,
    devminor => 0,
    prefix => '',
  );
  my %overrides = @_;
  foreach my $key (keys %overrides) {
    if (exists $hash{$key}) {
      $hash{$key} = $overrides{$key};
    }
    else {
      warn "invalid key $key for tar header\n";
    }
  }
  return \%hash;
}

=head2 CreateHeader

   my $block = $ts->CreateHeader($header);

Creates a 512 byte block from the TARHEADER format header.

=cut

sub CreateHeader {
  my $Self = shift;
  my $header = shift;

  my $block = pack("a100a8a8a8a12a12a8a1a100a8a32a32a8a8a155",
    $header->{name},
    sprintf("%07o", $header->{mode}),
    sprintf("%07o", $header->{uid}),
    sprintf("%07o", $header->{gid}),
    sprintf("%011o", $header->{size}),
    sprintf("%011o", $header->{mtime}),
    "        ",                  # chksum
    $header->{typeflag},
    $header->{linkname},
    "ustar\00000",                  # magic + version (POSIX ustar)
    $header->{uname},
    $header->{gname},
    sprintf("%07o", $header->{devmajor}),
    sprintf("%07o", $header->{devminor}),
    $header->{prefix},
  );

  # calculate checksum
  my $checksum = sprintf("%06o", unpack("%32C*", $block));
  substr($block, 148, 8) = $checksum . "\0 ";

  # pad out to BLOCKSIZE characters
  if (length($block) < BLOCKSIZE) {
    $block .= "\0" x (BLOCKSIZE - length($block));
  }
  elsif (length($block) > BLOCKSIZE) {
    $block = substr($block, 0, BLOCKSIZE);
  }

  return $block;
}

=head2 CopyBytes

   $ts->CopyBytes($bytes);

Copies bytes from input to output filehandle, rounded up to
block size, so only whole blocks are actually copied.

=cut

sub CopyBytes {
  my $Self = shift;
  my $bytes = shift;
  my $buf;
  while ($bytes > 0) {
    my $n = min(1 + int(($bytes-1) / BLOCKSIZE), BLOCKCOUNT);
    my $dump = $Self->ReadBlocks($n);
    $Self->WriteBlocks($dump, $n);
    $bytes -= length($dump);
  }
}

=head2 DumpBytes

   $ts->DumpBytes($bytes);

Just like CopyBytes, but it doesn't write anywhere.
Reads full blocks off the input filehandle, rounding
up to block size.

=cut

sub DumpBytes {
  my $Self = shift;
  my $bytes = shift;
  while ($bytes > 0) {
    my $n = min(1 + int(($bytes-1) / BLOCKSIZE), BLOCKCOUNT);
    my $dump = $Self->ReadBlocks($n);
    $bytes -= length($dump);
  }
}

=head2 FinishTar

   $ts->FinishTar();

Writes 2 blocks of zero bytes to the output file to signal
end-of-archive per the POSIX tar specification.

Don't use this if you're planning on concatenating multiple
files together.

=cut

sub FinishTar {
  my $Self = shift;
  # two blocks of all zero marks end-of-archive per POSIX tar spec
  $Self->WriteBlocks("", 2);
}

=head2 CopyToTempFile

   my $fh = $ts->CopyToTempFile($header->{size});

Creates a temporary file (with File::Temp) and fills it with
the contents of the file on the input stream.  It reads
entire blocks, and discards the padding.

=cut

sub CopyToTempFile {
  my $Self = shift;
  my $bytes = shift;

  my $TempFile = File::Temp->new();
  while ($bytes > 0) {
    my $n = min(1 + int(($bytes - 1) / BLOCKSIZE), BLOCKCOUNT);
    my $dump = $Self->ReadBlocks($n);
    die "Failed to read $n blocks for $bytes at $Self->{inpos}\n" unless defined $dump;
    $dump = substr($dump, 0, $bytes) if length($dump) > $bytes;
    $TempFile->print($dump);
    $bytes -= length($dump);
  }
  seek($TempFile, 0, 0);

  return $TempFile;
}

=head2 CopyFromFh

   $ts->CopyFromFh($fh, $header->{size});

Copies the contents of the filehandle to the output stream,
padding out to block size.

=cut

sub CopyFromFh {
  my $Self = shift;
  my $Fh = shift;
  my $bytes = shift;
  my $buf = shift // '';
  my $pos = shift // 0;

  my $tocopy = $bytes + $pos;

  while ($tocopy) {
    my $chunk = min($tocopy - $pos, BUFSIZE);
    if ($chunk) {
      my $n = sysread($Fh, $buf, $chunk, $pos);
      unless ($n) {
        die "Failed to read $chunk bytes from input fh at at $pos\n";
      }
      $pos += $n;
    }

    # if we're done, write including padding
    if ($pos == $tocopy) {
      my $nblocks = 1 + int(($pos-1) / BLOCKSIZE);
      $Self->WriteBlocks($buf, $nblocks);
      return;
    }

    # if we have any full blocks, write them out
    my $nblocks = int($pos / BLOCKSIZE);
    if ($nblocks) {
      $Self->WriteBlocks($buf, $nblocks);
      # keep any partial blocks
      my $written = $nblocks * BLOCKSIZE;
      $buf = substr($buf, $written);
      $pos -= $written;
      $tocopy -= $written;
    }
  }

  die "Finished copying without writing everything\n";
}

=head2 WriteFromFh

   $ts->WriteFromFh($fh, $header);

Writes the header and file data from $fh to the output stream.
If the name or linkname exceeds 100 bytes, GNU long name/link
extension entries are emitted automatically before the header.

=cut

sub WriteFromFh {
  my $Self = shift;
  my $Fh = shift;
  my $header = shift;

  $Self->_WriteLongEntries($header);
  my $pos = $Self->{outpos};

  my $block = $Self->CreateHeader($header);
  $Self->CopyFromFh($Fh, $header->{size}, $block, BLOCKSIZE);

  return( {%$header, _pos => $pos} );
}

=head2 WriteCopy

   $ts->WriteCopy($header);

Streams the record which matches the given header directly
from the input stream to the output stream.  If the name or
linkname exceeds 100 bytes, GNU long name/link extension
entries are emitted automatically before the header.

=cut

sub WriteCopy {
  my $Self = shift;
  my $header = shift;

  $Self->_WriteLongEntries($header);
  my $pos = $Self->{outpos};

  my $toread = $header->{size};

  my $blocks = $Self->CreateHeader($header);
  my $count = 1;

  while ($count || $toread > 0) {
    if ($toread) {
      my $n = min(1 + int(($toread-1) / BLOCKSIZE), BLOCKCOUNT-$count);
      my $dump = $Self->ReadBlocks($n);
      die "Failed to read $n blocks for $toread at $Self->{inpos}\n" unless defined $dump;
      $blocks .= $dump;
      $count += $n;
      $toread -= length($dump);
    }
    $Self->WriteBlocks($blocks, $count);
    $blocks = '';
    $count = 0;
  }

  return( {%$header, _pos => $pos} );
}

=head1 TARHEADER format

Headers are represented as hashrefs with the following fields
(these are the defaults from C<BlankHeader>):

  {
    name     => '',        # file path (any length; L/K emitted automatically)
    mode     => 0777,      # file permissions
    uid      => 0,         # owner user id
    gid      => 0,         # owner group id
    size     => 0,         # file size in bytes
    mtime    => time(),    # modification time (epoch seconds)
    typeflag => '0',       # entry type (see below)
    linkname => '',        # link target (any length; L/K emitted automatically)
    uname    => '',        # owner user name
    gname    => '',        # owner group name
    devmajor => 0,         # device major number
    devminor => 0,         # device minor number
    prefix   => '',        # ustar path prefix (used internally)
  }

The on-disk format is POSIX ustar.  Filenames and link targets
longer than 100 bytes are handled transparently using GNU tar
long name extensions (typeflag C<L> and C<K>).

See L<https://en.wikipedia.org/wiki/Tar_(file_format)#UStar_format>
for details on the ustar header layout.

B<Type flags:>

  '0'         Normal file
  (ASCII NUL) Normal file (V7 compat, obsolete)
  '1'         Hard link
  '2'         Symbolic link
  '3'         Character special
  '4'         Block special
  '5'         Directory
  '6'         FIFO
  '7'         Contiguous file

=head1 AUTHOR

Bron Gondwana, C<< <perlcode at brong.net> >>

=head1 BUGS

Please report bugs and feature requests on GitHub:

L<https://github.com/brong/Archive-Tar-Stream/issues>

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Archive::Tar::Stream

=over 4

=item * GitHub repository

L<https://github.com/brong/Archive-Tar-Stream>

=item * MetaCPAN

L<https://metacpan.org/dist/Archive-Tar-Stream>

=back


=head1 LICENSE AND COPYRIGHT

Copyright 2011 Opera Software Australia Pty Limited

This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation; or the Artistic License.

See http://dev.perl.org/licenses/ for more information.


=cut

1; # End of Archive::Tar::Stream
