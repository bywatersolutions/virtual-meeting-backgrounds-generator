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
    wrap_words wrap_title_text split_layers
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
# {{KEY+N}} is the (numeric) value of KEY plus the integer N, so a template can
# size or offset an element from a computed value, e.g. {{TITLE_EXTRA_HEIGHT+118}}.
sub fill_template {
    my ($svg, $map) = @_;
    $svg =~ s/\{\{(\w+)(?:\+(\d+))?\}\}/
        !exists $map->{$1} ? $&
      : defined $2         ? $map->{$1} + $2
      :                      $map->{$1} /ge;
    return $svg;
}

# Greedy word wrap: split text into lines of at most $width characters without
# breaking a word. A single word longer than $width gets a line to itself.
sub wrap_words {
    my ( $text, $width ) = @_;
    my @lines;
    for my $word ( split ' ', squish($text) ) {
        if ( @lines && length( $lines[-1] ) + 1 + length($word) <= $width ) {
            $lines[-1] .= " $word";
        } else {
            push @lines, $word;
        }
    }
    return @lines ? @lines : ('');
}

# Turn a wrapped title into a multi-line SVG text block.
#   my ($svg, $extra_height) = wrap_title_text($svg, { TITLE_UPPER => \@lines, ... });
# For each <text ...>{{KEY}}</text> whose KEY has more than one line, the
# placeholder becomes the first line plus one <tspan> per further line, using the
# element's own x and a line height of 1.25 x its font-size. Lines must already be
# XML-escaped. One-line values are left as the placeholder for fill_template, so
# their output is byte-identical to an unwrapped title. Returns the SVG and the
# height in px the extra lines add (0 when nothing wrapped).
sub wrap_title_text {
    my ( $svg, $lines_for ) = @_;
    my $extra_height = 0;
    $svg =~ s{(<text\b([^>]*)>)\{\{(\w+)\}\}(?=\s*</text>)}{
        my ( $open, $attrs, $key ) = ( $1, $2, $3 );
        my $lines = $lines_for->{$key};
        if ( !$lines || @$lines < 2 ) {
            $open . '{{' . $key . '}}';
        } else {
            my ($x)         = $attrs =~ /\bx="([^"]*)"/;
            my ($font_size) = $attrs =~ /\bfont-size="([\d.]+)"/;
            my $line_height = int( ( $font_size // 16 ) * 1.25 + 0.5 );
            my $height      = $#$lines * $line_height;
            $extra_height = $height if $height > $extra_height;
            $x //= 0;
            $open . $lines->[0]
                . join '', map { qq{<tspan x="$x" dy="$line_height">$_</tspan>} } @$lines[ 1 .. $#$lines ];
        }
    }ge;
    return ( $svg, $extra_height );
}

# Split a template into a background layer and a foreground layer that stack back
# into the original image.
#   my ($background_svg, $foreground_svg) = split_layers($template_svg);
# Each top-level element of the <svg> goes to one layer: an element containing a
# {{PLACEHOLDER}} (name/title block, logo) is foreground, anything else (fills,
# photos, scrims) is background, and <defs> is copied to both. Comments are
# ignored. Returns an empty list when either layer would be empty, e.g. for the
# transparent foreground-only templates.
sub split_layers {
    my $svg = shift // '';
    my ( $head, $inner ) = $svg =~ m{\A(.*?<svg\b[^>]*>)(.*)</svg>\s*\z}s or return;

    my ( @defs, @background, @foreground );
    my ( $depth, $start, $name ) = ( 0, 0, '' );
    while ( $inner =~ m{(<!--.*?-->)|<(/?)([\w:.-]+)[^>]*?(/?)>}gs ) {
        next if defined $1;
        my ( $closing, $tag, $self_closing ) = ( $2, $3, $4 );
        if ($closing) {
            $depth--;
        } else {
            ( $start, $name ) = ( $-[0], $tag ) if $depth == 0;
            $depth++ unless $self_closing;
        }
        next if $depth > 0;

        my $node = substr( $inner, $start, $+[0] - $start );
        ( my $without_comments = $node ) =~ s/<!--.*?-->//gs;
        if    ( $name eq 'defs' )                  { push @defs,       $node }
        elsif ( $without_comments =~ /\{\{\w+/ )   { push @foreground, $node }
        else                                       { push @background, $node }
    }
    return unless @background && @foreground;

    return map { join( "\n  ", $head, @defs, @$_ ) . "\n</svg>\n" } \@background, \@foreground;
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
