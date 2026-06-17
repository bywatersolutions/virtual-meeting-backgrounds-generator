package ByWater::MeetingBackgrounds;
# Shared helpers for the meeting-background generator: slugging, SVG templating,
# change-detection fingerprints, the file-size guard, and reading the people YAML.
# (HTML scraping and writing the YAML live in scripts/fetch.pl — they're only
# needed by stage 1.) Digest::SHA and YAML::PP are loaded lazily, so the pure
# string helpers and `perl -c` work without them installed.
use strict;
use warnings;
use utf8;
use Exporter 'import';
use MIME::Base64 qw(encode_base64);

our @EXPORT_OK = qw(
    slugify squish uc_safe xml_escape
    fill_template build_logo_uri
    fingerprint needs_render discover_templates within_size_limit
    read_people
);

# Collapse internal whitespace and trim.
sub squish {
    my $s = shift // '';
    $s =~ s/\s+/ /g;
    $s =~ s/^\s+|\s+$//g;
    return $s;
}

sub uc_safe { my $s = shift // ''; return uc $s; }

# Directory-safe slug: "Brendan A. Gallagher" -> "Brendan-A-Gallagher"
sub slugify {
    my $s = squish(shift // '');
    $s =~ s/[^\p{L}\p{N}]+/-/g;   # any run of non-alphanumerics -> single hyphen
    $s =~ s/^-+|-+$//g;
    return $s;
}

sub xml_escape {
    my $s = shift // '';
    $s =~ s/&/&amp;/g;
    $s =~ s/</&lt;/g;
    $s =~ s/>/&gt;/g;
    $s =~ s/"/&quot;/g;
    return $s;
}

# Substitute {{PLACEHOLDER}} tokens; unknown tokens are left untouched.
sub fill_template {
    my ($svg, $map) = @_;
    $svg =~ s/\{\{(\w+)\}\}/ exists $map->{$1} ? $map->{$1} : "{{$1}}" /ge;
    return $svg;
}

# Build a data: URI for the logo PNG.
sub build_logo_uri {
    my $path = shift;
    open(my $fh, '<:raw', $path) or die "read $path: $!";
    local $/; my $bytes = <$fh>; close $fh;
    return 'data:image/png;base64,' . encode_base64($bytes, '');
}

# Stable content hash of an already-filled SVG string. The filled SVG embeds the
# template markup, the name, the title, and the logo data: URI, so this one hash
# changes whenever any of those change. Encode to UTF-8 bytes first so wide chars
# don't die and the hash doesn't depend on the scalar's internal utf8 flag.
sub fingerprint {
    my $filled = shift // '';
    require Digest::SHA;
    require Encode;
    return Digest::SHA::sha1_hex( Encode::encode_utf8($filled) );
}

# Decide whether a background needs (re)rendering. Pure, no I/O.
#   needs_render($force, $out_exists, $old_fp, $new_fp)
# Re-render when forced, when the PNG is missing, when we have no stored
# fingerprint, or when the stored fingerprint differs from the current one.
sub needs_render {
    my ( $force, $out_exists, $old_fp, $new_fp ) = @_;
    return 1 if $force;
    return 1 if !$out_exists;
    return 1 if !defined $old_fp;
    return 1 if $old_fp ne $new_fp;
    return 0;
}

# Renderable templates in a directory: *.svg, minus author scaffolds whose
# basename starts with '_' (e.g. _starter.svg). Returns sorted absolute paths.
sub discover_templates {
    my $dir = shift;
    require File::Basename;
    return sort grep { File::Basename::basename($_) !~ /^_/ } glob("$dir/*.svg");
}

# True if a byte count is at or under the (inclusive) limit. Used to keep every
# rendered background under the platform file-size cap (Zoom rejects > 5 MB).
sub within_size_limit {
    my ( $bytes, $max ) = @_;
    return ( $bytes // 0 ) <= $max ? 1 : 0;
}

# Read a people YAML file (written by stage 1) into a list of { name, title, slug }
# hashrefs. This is the render side of the stage-1/stage-2 hand-off.
sub read_people {
    my ($path) = @_;
    require YAML::PP;
    my $data = YAML::PP->new->load_file($path);
    return ref $data eq 'ARRAY' ? @$data : ();
}

1;
