#!/usr/bin/env perl
#
# make-mono-logos.pl — generate the monochrome logo assets from the flat logo.
#
# Templates can pick a logo treatment via placeholders: {{LOGO}} (the full-color
# assets/bywater_logo.png), {{LOGO_WHITE}}, or {{LOGO_BLACK}}. This script produces
# the white and black versions the last two need by recoloring the *flat* logo
# (assets/bywater_logo_flat.png): it forces every pixel's RGB to white (or black)
# while keeping the original alpha.
#
# The recolor source matters. The flat logo draws the icon's chevron "pages" as
# transparent negative space, so a single-color recolor keeps them as clean
# cut-outs. The glossy bywater_logo.png paints those chevrons as opaque pixels, so
# recoloring it collapses the icon into a featureless blob — which is why the flat
# logo is the source here.
#
# It does the recolor with rsvg-convert (already required to render backgrounds)
# and an feColorMatrix filter, so there's no ImageMagick dependency. Run it again
# (make logos) whenever assets/bywater_logo_flat.png changes, then commit the results.
#
# Output (committed alongside the source logo):
#   assets/bywater_logo_white.png
#   assets/bywater_logo_black.png
#
use strict;
use warnings;
use feature 'say';
use FindBin qw($RealBin);
use lib "$RealBin/../lib";
use File::Spec;
use ByWater::MeetingBackgrounds qw(build_logo_uri);

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

my $ROOT       = File::Spec->rel2abs("$RealBin/..");
my $ASSETS     = "$ROOT/assets";
my $LOGO_PATH  = "$ASSETS/bywater_logo_flat.png";

# feColorMatrix values per variant: zero out the RGB contribution from the
# source and set each channel to a constant (1 = white, 0 = black) via the last
# column, while the alpha row copies the source alpha unchanged (0 0 0 1 0).
my %VARIANT = (
    white => '0 0 0 0 1  0 0 0 0 1  0 0 0 0 1  0 0 0 1 0',
    black => '0 0 0 0 0  0 0 0 0 0  0 0 0 0 0  0 0 0 1 0',
);

die "Source logo not found: $LOGO_PATH\n" unless -f $LOGO_PATH;
die "rsvg-convert not found on PATH (install librsvg2-bin)\n"
    unless `command -v rsvg-convert 2>/dev/null`;

my ( $w, $h ) = png_size($LOGO_PATH);
my $logo_uri  = build_logo_uri($LOGO_PATH);

for my $variant ( sort keys %VARIANT ) {
    my $out = "$ASSETS/bywater_logo_$variant.png";
    recolor( $logo_uri, $w, $h, $VARIANT{$variant}, $out );
    say "Wrote $out (${w}x${h}, $variant)";
}

# Render the master logo through an feColorMatrix recolor filter to a PNG of the
# same size, preserving alpha.
sub recolor {
    my ( $uri, $width, $height, $matrix, $out ) = @_;

    # color-interpolation-filters="sRGB" keeps the recolor in gamma space so the
    # constant white/black isn't shifted; the alpha edges come straight from the
    # source. Emit both href spellings for renderer compatibility, as the
    # templates do.
    my $svg = <<"SVG";
<svg width="$width" height="$height" viewBox="0 0 $width $height" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink">
  <defs>
    <filter id="recolor" x="0" y="0" width="100%" height="100%" color-interpolation-filters="sRGB">
      <feColorMatrix type="matrix" values="$matrix"/>
    </filter>
  </defs>
  <image x="0" y="0" width="$width" height="$height" xlink:href="$uri" href="$uri" filter="url(#recolor)"/>
</svg>
SVG

    my $tmp = "$out.tmp.svg";
    open( my $fh, '>:raw', $tmp ) or die "write $tmp: $!";
    print $fh $svg;
    close $fh;

    my $rc = system( 'rsvg-convert', '-o', $out, $tmp );
    unlink $tmp;
    die "rsvg-convert failed (exit @{[ $rc >> 8 ]}) for $out\n" if $rc != 0;
}

# Read a PNG's pixel dimensions straight from its IHDR chunk: 8-byte signature,
# 4-byte length, "IHDR", then width and height as big-endian 32-bit integers.
sub png_size {
    my $path = shift;
    open( my $fh, '<:raw', $path ) or die "read $path: $!";
    read( $fh, my $header, 24 ) == 24 or die "$path: too small to be a PNG\n";
    close $fh;
    die "$path: not a PNG\n" unless substr( $header, 0, 8 ) eq "\x89PNG\r\n\x1a\n";
    return unpack( 'N N', substr( $header, 16, 8 ) );
}
