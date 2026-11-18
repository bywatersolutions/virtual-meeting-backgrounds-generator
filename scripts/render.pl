#!/usr/bin/env perl
#
# render.pl — stage 2: read the people YAML and render their backgrounds.
#
# Stage 1 (fetch.pl) produces the people YAML by scraping the team page; this
# stage is offline. It:
#   1. Reads people (name, title, slug) from the YAML file.
#   2. Prunes staff/<slug>/ directories for people no longer in the YAML.
#   3. For each person x template, renders staff/<slug>/<template>.png — but only
#      when something changed. The fingerprint of the filled SVG (template markup +
#      name + title + logo) is stored in the manifest; a background is re-rendered
#      only if that fingerprint changed, the PNG is missing, or FORCE=1 is set.
#   4. For each template that has background art, also renders a "split" pair
#      that stacks back into the same image: the art alone, once for everyone, as
#      staff/_shared/<template>-split-background.png, and each person's text + logo
#      on a transparent canvas as staff/<slug>/<template>-split-foreground.png.
#
# Titles are word-wrapped at TITLE_WRAP_WIDTH characters (never mid-word).
#
# Each template renders at its own size: 16:9 templates are 1920x1080 (the default
# Zoom/Teams/Meet size) and the 4:3 "-original" templates are 1440x1080 (for Zoom's
# opt-in Original Ratio). Each PNG is kept under a 5 MB file-size cap so it uploads
# everywhere (Zoom rejects backgrounds over 5 MB); oversized PNGs are optimized with
# pngquant when available, and the run fails if one still won't fit.
# Rendering shells out to `rsvg-convert` (librsvg). See README "Why Perl + rsvg".
#
# Environment overrides:
#   PEOPLE_FILE  input YAML path (default: <repo>/data/people.yaml)
#   OUTPUT_DIR   output directory (default: <repo>/staff) — handy for previews
#   FORCE        truthy => re-render even if nothing changed
#   DRY_RUN      truthy => report the people; no prune, no render
#   WIDTH/HEIGHT optional output-size override (default: the template's own size)
#   MAX_BYTES    per-file size cap in bytes (default 5_000_000)
#
use strict;
use warnings;
use feature 'say';
use utf8;
use FindBin qw($RealBin);
use lib "$RealBin/../lib";
use File::Spec;
use File::Basename qw(basename);
use File::Path qw(make_path remove_tree);
use Encode qw(decode_utf8);
use JSON::PP;
use ByWater::MeetingBackgrounds qw(read_people slugify uc_safe xml_escape
                                   fill_template build_logo_uri
                                   wrap_words wrap_title_text split_layers
                                   fingerprint needs_render discover_templates within_size_limit);

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

# ---- configuration -------------------------------------------------------
my $ROOT         = File::Spec->rel2abs("$RealBin/..");
my $TEMPLATE_DIR = "$ROOT/templates";
my $LOGO_PATH    = "$ROOT/assets/bywater_logo.png";
my $LOGO_WHITE   = "$ROOT/assets/bywater_logo_white.png";   # {{LOGO_WHITE}} — for dark backgrounds
my $LOGO_BLACK   = "$ROOT/assets/bywater_logo_black.png";   # {{LOGO_BLACK}} — for light backgrounds
my $PEOPLE_FILE  = $ENV{PEOPLE_FILE} // "$ROOT/data/people.yaml";
my $OUTPUT_DIR   = $ENV{OUTPUT_DIR}  // "$ROOT/staff";
my $WIDTH        = $ENV{WIDTH};    # optional override; default = the template's own size
my $HEIGHT       = $ENV{HEIGHT};
my $MAX_BYTES    = $ENV{MAX_BYTES} // 5_000_000;   # per-file cap; Zoom rejects > 5 MB
my $TITLE_WRAP_WIDTH = 20;         # titles wrap onto a new line past this many characters
my $SHARED_DIR   = '_shared';      # holds the split backgrounds, which are the same for everyone
my $FORCE        = $ENV{FORCE}   ? 1 : 0;
my $DRY_RUN      = $ENV{DRY_RUN} ? 1 : 0;

# ---- preflight -----------------------------------------------------------
die "People file not found: $PEOPLE_FILE (run fetch.pl first)\n" unless -f $PEOPLE_FILE;
die "Logo not found: $LOGO_PATH\n" unless -f $LOGO_PATH;
for my $mono ( $LOGO_WHITE, $LOGO_BLACK ) {
    die "Monochrome logo not found: $mono (run 'make logos')\n" unless -f $mono;
}
my @templates = discover_templates($TEMPLATE_DIR);
die "No templates found in $TEMPLATE_DIR\n" unless @templates;
unless ($DRY_RUN) {
    die "rsvg-convert not found on PATH (install librsvg2-bin)\n"
        unless `command -v rsvg-convert 2>/dev/null`;
}

# ---- 1. read people ------------------------------------------------------
my @people = read_people($PEOPLE_FILE);
die "No people in $PEOPLE_FILE\n" unless @people;
$_->{slug} //= slugify( $_->{name} ) for @people;   # tolerate hand-edited YAML
@people = sort { $a->{slug} cmp $b->{slug} } @people;
say "Read " . scalar(@people) . " people, " . scalar(@templates) . " template(s) from $PEOPLE_FILE";

if ($DRY_RUN) {
    say sprintf("  %-28s %-28s %s", 'SLUG', 'NAME', 'TITLE');
    say sprintf("  %-28s %-28s %s", $_->{slug}, $_->{name}, $_->{title}) for @people;
    say "DRY_RUN: nothing rendered.";
    exit 0;
}

# Stored fingerprints from the previous run, keyed by slug.
my %manifest = %{ read_manifest("$OUTPUT_DIR/manifest.json") };

# ---- 2. prune people who left --------------------------------------------
my %valid_slug = map { $_->{slug} => 1 } @people;
if (-d $OUTPUT_DIR) {
    opendir(my $dh, $OUTPUT_DIR) or die "opendir $OUTPUT_DIR: $!";
    for my $entry (sort readdir $dh) {
        next if $entry =~ /^\./;
        # readdir yields raw bytes; decode so accented slugs match %valid_slug
        # (which is keyed by the decoded names read from the YAML).
        my $slug = decode_utf8($entry);
        my $path = "$OUTPUT_DIR/$slug";
        next unless -d $path;
        next if $slug eq $SHARED_DIR;
        next if $valid_slug{$slug};
        say "Pruning '$slug' (no longer in people file)";
        remove_tree($path);
        delete $manifest{$slug};
    }
    closedir $dh;
}

# ---- 3. render backgrounds whose content changed -------------------------
my %logo_uri = (
    LOGO       => build_logo_uri($LOGO_PATH),
    LOGO_WHITE => build_logo_uri($LOGO_WHITE),
    LOGO_BLACK => build_logo_uri($LOGO_BLACK),
);
my $rendered = 0;

# Split each template that has background art into its two layers. The
# background layer has no per-person content, so it is rendered once, here.
my %split_foreground;
my %shared_manifest = %{ read_shared_manifest("$OUTPUT_DIR/$SHARED_DIR/manifest.json") };
my %shared_renders;
for my $tpl (@templates) {
    (my $tname = basename($tpl)) =~ s/\.svg$//;
    my ( $background, $foreground ) = split_layers( read_template($tpl) ) or next;
    $split_foreground{$tname} = $foreground;

    my $bname  = "$tname-split-background";
    my $out    = "$OUTPUT_DIR/$SHARED_DIR/$bname.png";
    my $new_fp = fingerprint($background);
    if (needs_render($FORCE, -e $out, $shared_manifest{$bname}, $new_fp)) {
        make_path("$OUTPUT_DIR/$SHARED_DIR");
        rasterize($background, $out);
        say "  rendered $SHARED_DIR/$bname.png";
        $rendered++;
    }
    $shared_renders{$bname} = $new_fp;
}

for my $person (@people) {
    my $slug = $person->{slug};
    my $dir  = "$OUTPUT_DIR/$slug";
    make_path($dir);
    for my $tpl (@templates) {
        (my $tname = basename($tpl)) =~ s/\.svg$//;
        my $out    = "$dir/$tname.png";
        my $filled = fill_one(read_template($tpl), $person, \%logo_uri);
        my $new_fp = fingerprint($filled);
        my $old_fp = $manifest{$slug}{renders}{$tname};
        if (needs_render($FORCE, -e $out, $old_fp, $new_fp)) {
            rasterize($filled, $out);
            say "  rendered $slug/$tname.png";
            $rendered++;
        }
        $manifest{$slug}{renders}{$tname} = $new_fp;

        # The transparent text + logo half of the split pair, if this template has one.
        next unless $split_foreground{$tname};
        my $fname = "$tname-split-foreground";
        $out    = "$dir/$fname.png";
        $filled = fill_one($split_foreground{$tname}, $person, \%logo_uri);
        $new_fp = fingerprint($filled);
        $old_fp = $manifest{$slug}{renders}{$fname};
        if (needs_render($FORCE, -e $out, $old_fp, $new_fp)) {
            rasterize($filled, $out);
            say "  rendered $slug/$fname.png";
            $rendered++;
        }
        $manifest{$slug}{renders}{$fname} = $new_fp;
    }
}

# ---- 4. manifest ---------------------------------------------------------
make_path($OUTPUT_DIR);
my @rows = map {
    +{
        slug    => $_->{slug},
        name    => $_->{name},
        title   => $_->{title},
        renders => ( $manifest{ $_->{slug} }{renders} // {} ),
    }
} @people;
my $json = JSON::PP->new->utf8->canonical->pretty->encode(\@rows);
open(my $mf, '>:raw', "$OUTPUT_DIR/manifest.json") or die $!;
print $mf $json;
close $mf;

if (%shared_renders) {
    my $shared_json = JSON::PP->new->utf8->canonical->pretty->encode(\%shared_renders);
    open(my $sf, '>:raw', "$OUTPUT_DIR/$SHARED_DIR/manifest.json") or die $!;
    print $sf $shared_json;
    close $sf;
}

say "Done. Rendered $rendered new file(s).";

# ==========================================================================
# Read a template file into a string.
sub read_template {
    my ($tpl) = @_;
    open(my $tf, '<:encoding(UTF-8)', $tpl) or die "read $tpl: $!";
    local $/; my $svg = <$tf>; close $tf;
    return $svg;
}

# Substitute the per-person placeholders in a template string; return the filled SVG.
sub fill_one {
    my ($svg, $person, $logos) = @_;

    # Wrap on the raw title so an escaped '&amp;' still counts as one character.
    my @title_lines = wrap_words($person->{title}, $TITLE_WRAP_WIDTH);
    ($svg, my $title_extra_height) = wrap_title_text($svg, {
        TITLE       => [ map { xml_escape($_) } @title_lines ],
        TITLE_UPPER => [ map { xml_escape(uc_safe($_)) } @title_lines ],
    });

    return fill_template($svg, {
        TITLE_EXTRA_HEIGHT => $title_extra_height,
        NAME        => xml_escape($person->{name}),
        TITLE       => xml_escape($person->{title}),
        NAME_UPPER  => xml_escape(uc_safe($person->{name})),
        TITLE_UPPER => xml_escape(uc_safe($person->{title})),
        LOGO        => $logos->{LOGO},
        LOGO_WHITE  => $logos->{LOGO_WHITE},
        LOGO_BLACK  => $logos->{LOGO_BLACK},
    });
}

# Rasterize a filled SVG string to a PNG via rsvg-convert at the template's own
# size (unless WIDTH/HEIGHT override it), then make sure it fits under the cap.
sub rasterize {
    my ($filled, $out) = @_;
    my $tmp = "$out.tmp.svg";
    open(my $fh, '>:encoding(UTF-8)', $tmp) or die "write $tmp: $!";
    print $fh $filled;
    close $fh;

    my @size;
    push @size, '-w', $WIDTH  if defined $WIDTH;
    push @size, '-h', $HEIGHT if defined $HEIGHT;
    my $rc = system('rsvg-convert', @size, '-o', $out, $tmp);
    unlink $tmp;
    die "rsvg-convert failed (exit @{[ $rc >> 8 ]}) for $out\n" if $rc != 0;

    shrink_to_limit($out, $MAX_BYTES);
}

# Keep a rendered PNG under the file-size cap. Optimizes in place with pngquant
# when available; dies if the result still won't fit, so a too-heavy template is
# caught here rather than producing a background some platforms reject.
sub shrink_to_limit {
    my ($out, $max) = @_;
    return if within_size_limit(-s $out, $max);

    if (`command -v pngquant 2>/dev/null`) {
        # Quantize in place; --skip-if-larger leaves the original if it can't help.
        system('pngquant', '--force', '--skip-if-larger', '--strip',
               '--quality=40-95', '--output', $out, '--', $out);
    }

    die sprintf(
        "%s is %.1f MB, over the %.1f MB limit — simplify the template "
            . "(e.g. shrink any embedded raster image) or raise MAX_BYTES\n",
        $out, ( -s $out ) / 1_000_000, $max / 1_000_000
    ) unless within_size_limit(-s $out, $max);
}

# Load the shared (split background) fingerprints: { name => sha }. A missing or
# corrupt file is treated as empty.
sub read_shared_manifest {
    my $path = shift;
    return {} unless -e $path;
    my $data = eval {
        open(my $fh, '<:raw', $path) or die "read $path: $!\n";
        local $/; my $bytes = <$fh>; close $fh;
        JSON::PP->new->utf8->decode($bytes);
    };
    return ref $data eq 'HASH' ? $data : {};
}

# Load the previous manifest into { slug => { name, title, renders => {tpl=>sha} } }.
# Tolerates a missing, corrupt, or old-schema (no "renders") file by treating
# whatever it can't use as empty.
sub read_manifest {
    my $path = shift;
    my %m;
    return \%m unless -e $path;
    my $data = eval {
        open(my $fh, '<:raw', $path) or die "read $path: $!\n";
        local $/; my $bytes = <$fh>; close $fh;
        JSON::PP->new->utf8->decode($bytes);
    };
    return \%m unless ref $data eq 'ARRAY';
    for my $row (@$data) {
        next unless ref $row eq 'HASH' && defined $row->{slug};
        $m{ $row->{slug} } = {
            name    => $row->{name}  // '',
            title   => $row->{title} // '',
            renders => ( ref $row->{renders} eq 'HASH' ? $row->{renders} : {} ),
        };
    }
    return \%m;
}
